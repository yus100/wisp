import AppKit
import Foundation

/// `Wisp ctl <command>` drives the running app from a shell (other launchers, scripts, smoke tests).
/// Commands travel as distributed notifications, which only processes in your login session can post.
enum ControlCommand {
    static let notification = Notification.Name("com.yus100.wisp.ctl")

    static let usage = """
    usage: Wisp ctl <command> [argument]

      toggle | show | hide      show or hide the panel
      voice                     start hands-free voice, or stop and send
      ask <text>                open the panel and send a question
      new                       start a new conversation
      ghostty                   continue the current conversation in Ghostty
      state <file.json>         write the panel state as JSON
      snapshot <file.png>       render the panel to a PNG
      type <text>               type text into the panel as key presses
      key <keys>                press a key, e.g. return, escape, cmd+return, cmd+n
      voice-file <file.wav>     dictate a 16 kHz mono WAV file instead of the microphone
    """

    /// Client side: post the command and, for commands that write a file, wait for it.
    static func runClient(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 2
        }
        var argument = arguments.dropFirst().joined(separator: " ")
        let writesFile = ["state", "snapshot"].contains(command)
        if writesFile || command == "voice-file" {
            argument = URL(fileURLWithPath: argument).standardizedFileURL.path
        }
        if writesFile { try? FileManager.default.removeItem(atPath: argument) }
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: ["command": command, "argument": argument], deliverImmediately: true)
        guard writesFile else { return 0 }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: argument) { return 0 }
            Thread.sleep(forTimeInterval: 0.05)
        }
        FileHandle.standardError.write(Data("timed out waiting for \(argument); is Wisp running?\n".utf8))
        return 1
    }
}

@MainActor
final class ControlServer {
    private weak var delegate: AppDelegate?
    private var observer: NSObjectProtocol?

    init(delegate: AppDelegate) {
        self.delegate = delegate
        observer = DistributedNotificationCenter.default().addObserver(
            forName: ControlCommand.notification, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?["command"] as? String ?? ""
            let argument = note.userInfo?["argument"] as? String ?? ""
            Task { @MainActor in self?.run(command, argument) }
        }
    }

    private func run(_ command: String, _ argument: String) {
        guard let delegate else { return }
        let model = delegate.spotlightModel
        let panel = delegate.panel!
        switch command {
        case "toggle": delegate.togglePanel()
        case "show": delegate.showPanel()
        case "hide": panel.hide()
        case "voice": delegate.toggleVoice()
        case "ask":
            delegate.showPanel()
            model.submit(argument)
        case "new": model.newConversation()
        case "ghostty": model.openInGhostty()
        case "snapshot": panel.snapshot(to: URL(fileURLWithPath: argument))
        case "state": writeState(model, panel: panel, to: argument)
        case "type":
            for character in argument {
                panel.simulateKey(keyCode: 0, characters: String(character), modifiers: [])
            }
        case "key": pressKeys(argument, panel: panel)
        case "voice-file":
            delegate.showPanel()
            model.startVoice(mode: .handsFree, file: URL(fileURLWithPath: argument))
        default:
            appLog("ctl: unknown command \(command)")
        }
    }

    private func pressKeys(_ spec: String, panel: PanelController) {
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
        let named: [String: (UInt16, String)] = [
            "return": (36, "\r"), "enter": (76, "\u{3}"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
            "tab": (48, "\t"), "delete": (51, "\u{7f}"), "n": (45, "n"), ".": (47, "."), "w": (13, "w"),
            "c": (8, "c"),
        ]
        guard let (code, characters) = named[name] else {
            appLog("ctl: unknown key \(spec)")
            return
        }
        panel.simulateKey(keyCode: code, characters: characters, modifiers: modifiers)
    }

    private func writeState(_ model: WispModel, panel: PanelController, to path: String) {
        let turns: [JSON] = model.turns.map { turn in
            [
                "query": turn.query,
                "answer": turn.answer,
                "done": turn.done,
                "cancelled": turn.cancelled,
                "error": turn.error as Any,
                "tools": turn.tools.map { ["title": $0.title, "status": $0.status] },
            ]
        }
        let state: JSON = [
            "visible": panel.isVisible,
            "geometry": panel.geometry,
            "input": model.input,
            "isWorking": model.isWorking,
            "sessionId": model.sessionId as Any,
            "notice": model.notice as Any,
            "voice": ["active": model.voice.active, "connecting": model.voice.connecting,
                      "finishing": model.voice.finishing, "level": model.voice.level],
            "turns": turns,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
