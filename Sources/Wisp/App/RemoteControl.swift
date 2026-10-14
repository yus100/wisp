import AppKit
import WispCore

/// `Wisp ctl <command>` drives the running app from a shell, for scripts and scripts/smoke-test.sh.
///
/// Commands travel as distributed notifications. `show`, `hide`, and `toggle` always work. Everything
/// else needs `"remoteControl": true` in the config, because it lets any process running as you use
/// Wisp's microphone and file permissions through the always-approve agent. Files only move through
/// Wisp's own temporary folder; the client copies them in and out with its own permissions.
enum RemoteControl {
    static let notification = Notification.Name("com.yus100.wisp.ctl")
    static let alwaysAllowed: Set<String> = ["show", "hide", "toggle"]

    /// Where the app reads and writes files for `ctl`.
    static var exchange: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-ctl", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The `ctl` command-line side.
enum ControlClient {
    static let usage = """
        usage: Wisp ctl <command> [argument]

          show | hide | toggle      show or hide the panel

        These need "remoteControl": true in ~/.config/wisp/config.json:
          ask <text>                show the panel and send a question
          voice                     start hands-free voice, or stop and send
          voice-file <file.wav>     dictate a 16 kHz mono 16-bit WAV instead of the microphone
          new                       start a new conversation
          ghostty                   continue the current conversation in Ghostty
          model <id> | effort <e>   choose the model or reasoning effort
          type <text>               type text into the panel as key presses
          key <keys>                press keys, e.g. return, escape, cmd+return, cmd+n, shift+return
          state <out.json>          write the panel state as JSON
          snapshot <out.png>        render the panel to a PNG
        """

    static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first, command != "help", command != "--help" else {
            print(usage)
            return arguments.isEmpty ? 2 : 0
        }
        var argument = arguments.dropFirst().joined(separator: " ")
        var output: URL?
        switch command {
        case "state", "snapshot":
            guard !argument.isEmpty else { return fail("\(command) needs an output path") }
            output = URL(filePath: argument)
            argument = "\(UUID().uuidString).\(command == "state" ? "json" : "png")"
        case "voice-file":
            let staged = "\(UUID().uuidString).wav"
            do {
                try FileManager.default.copyItem(at: URL(filePath: argument), to: RemoteControl.exchange.appending(path: staged))
            } catch {
                return fail("cannot read \(argument): \(error.localizedDescription)")
            }
            argument = staged
        default:
            break
        }

        DistributedNotificationCenter.default().postNotificationName(
            RemoteControl.notification, object: nil,
            userInfo: ["command": command, "argument": argument], deliverImmediately: true)

        guard let output else { return 0 }
        let produced = RemoteControl.exchange.appending(path: argument)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: produced.path) {
                try? FileManager.default.removeItem(at: output)
                do {
                    try FileManager.default.moveItem(at: produced, to: output)
                    return 0
                } catch {
                    return fail("cannot write \(output.path): \(error.localizedDescription)")
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return fail("no reply. Is Wisp running with \"remoteControl\": true in its config?")
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Wisp ctl: \(message)\n".utf8))
        return 1
    }
}

/// The app side: runs commands against the panel and model.
@MainActor
final class ControlServer {
    private let model: AppModel
    private let panel: PanelController
    private let isEnabled: () -> Bool
    private var observer: NSObjectProtocol?

    init(model: AppModel, panel: PanelController, isEnabled: @escaping () -> Bool) {
        self.model = model
        self.panel = panel
        self.isEnabled = isEnabled
        observer = DistributedNotificationCenter.default().addObserver(
            forName: RemoteControl.notification, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?["command"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            MainActor.assumeIsolated { self?.run(command, argument) }
        }
    }

    private func run(_ command: String, _ argument: String) {
        pruneExchange()
        // A staged recording is consumed (or discarded) whatever happens to the command.
        let recording = command == "voice-file" ? takeExchangeFile(argument) : nil
        guard RemoteControl.alwaysAllowed.contains(command) || isEnabled() else {
            Log.info("ctl: ignored \(command); remoteControl is off")
            return
        }
        switch command {
        case "show": panel.show()
        case "hide": panel.hide()
        case "toggle": panel.toggle()
        case "ask":
            panel.show()
            model.submit(argument)
        case "voice":
            if model.voice.isActive {
                model.voice.finish(send: true)
            } else {
                panel.show()
                model.startVoice(.handsFree)
            }
        case "voice-file":
            guard let recording else { return }
            panel.show()
            model.startVoice(.handsFree, recording: recording)
        case "new": model.newConversation()
        case "ghostty": model.continueInGhostty()
        case "model": model.selectModel(argument)
        case "effort": model.selectEffort(argument)
        case "type":
            for character in argument { panel.simulateKey(code: 0, characters: String(character)) }
        case "key": press(argument)
        case "state": write(stateJSON(), to: argument)
        case "snapshot": write(panel.snapshotPNG(), to: argument)
        default: Log.info("ctl: unknown command \(command)")
        }
    }

    /// A file inside the exchange folder; anything else is refused.
    private func exchangeFile(_ name: String) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
            Log.info("ctl: refused file name \(name)")
            return nil
        }
        return RemoteControl.exchange.appending(path: name)
    }

    /// Reads and deletes a file the client staged.
    private func takeExchangeFile(_ name: String) -> Data? {
        guard let file = exchangeFile(name) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        return try? Data(contentsOf: file)
    }

    /// Clears files a client gave up waiting for.
    private func pruneExchange() {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-60)
        let files =
            (try? fileManager.contentsOfDirectory(
                at: RemoteControl.exchange, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
        }
    }

    private func write(_ data: Data?, to name: String) {
        guard let data, let file = exchangeFile(name) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func press(_ spec: String) {
        let keys: [String: (code: UInt16, characters: String)] = [
            "return": (36, "\r"), "enter": (76, "\u{3}"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
            "tab": (48, "\t"), "delete": (51, "\u{7f}"), "n": (45, "n"), "m": (46, "m"), ".": (47, "."),
            "w": (13, "w"), "c": (8, "c"), "v": (9, "v"), "a": (0, "a"),
        ]
        var modifiers: NSEvent.ModifierFlags = []
        var name = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: name = part
            }
        }
        guard let key = keys[name] else { return Log.info("ctl: unknown key \(spec)") }
        panel.simulateKey(code: key.code, characters: key.characters, modifiers: modifiers)
    }

    private func stateJSON() -> Data? {
        let turns: [[String: Any]] = model.conversation.turns.map { turn in
            var state = "running"
            var error: Any = NSNull()
            switch turn.state {
            case .running: state = "running"
            case .finished: state = "finished"
            case .cancelled: state = "cancelled"
            case .failed(let message):
                state = "failed"
                error = message
            }
            return [
                "query": turn.query, "answer": turn.answer, "state": state, "error": error,
                "model": turn.model ?? NSNull(), "steps": turn.steps.map(\.title),
            ]
        }
        let state: [String: Any] = [
            "visible": panel.isVisible,
            "frame": panel.frameDescription,
            "input": model.input,
            "isWorking": model.isWorking,
            "isHandingOff": model.isHandingOff,
            "sessionId": model.sessionID ?? NSNull(),
            "notice": model.notice?.text ?? NSNull(),
            "model": model.modelLabel,
            "models": model.catalog.models.map(\.id),
            "modelMenu": ModelMenu.make(for: model).items.map { item in
                item.isSeparatorItem ? "---" : (item.state == .on ? "✓ " : "") + item.title
            },
            "voice": ["state": "\(model.voice.state)", "level": model.voice.level],
            "turns": turns,
        ]
        return try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
    }
}
