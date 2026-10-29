import AppKit
import IOKit
import Testing
import WispCore

@testable import Wisp

/// Types into the real panel and checks the model chip. Gated on a quiet Mac: it is off unless
/// `WISP_LIVE_UI_TEST=1`, and it refuses to start unless the user has been idle for 45 seconds.
@Suite(.serialized) @MainActor
struct LiveComposerTests {
    private func idleTime() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return -1 }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber).map { $0.doubleValue / 1_000_000_000 } ?? -1
    }

    private func launchServices(_ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(filePath: "/usr/bin/lsappinfo")
        task.arguments = arguments
        task.standardOutput = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISP_LIVE_UI_TEST"] == "1"))
    func liveDeletionAndModelCatalog() async throws {
        let realConfig = WispPaths.standard.configFile
        let realBytes = try? Data(contentsOf: realConfig)
        if let realBytes {
            try #require(try JSONDecoder().decode(WispConfig.self, from: realBytes).remoteControl == false)
        }
        let environment = await ShellEnvironment.resolve()
        try #require(
            environment["GROK_HOME", default: ""].isEmpty,
            "Live test requires no external GROK_HOME so history stays isolated")
        var lastIdle = idleTime()
        try #require(lastIdle >= 45, "Live native test requires HIDIdleTime >= 45 seconds")
        let front = try launchServices(["front"])
        try #require(front.hasPrefix("ASN:"))

        let scratch = URL(filePath: "/tmp/wisp-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = WispPaths(home: scratch)
        let fixture = try #require(Bundle.module.url(forResource: "catalog-agent", withExtension: "py", subdirectory: "Fixtures"))
        let executable = scratch.appending(path: "catalog-agent.py")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = WispConfig()
        config.grokPath = executable.path
        config.workingDirectory = scratch.path
        config.launchAtLogin = false
        config.notifyWhenDone = false
        config.remoteControl = false
        config.idleResetMinutes = 0
        try config.save(to: paths.configFile)
        let scratchBytes = try Data(contentsOf: paths.configFile)

        _ = NSApplication.shared
        let model = AppModel(configStore: ConfigStore(file: paths.configFile), paths: paths)
        let panel = PanelController(model: model)
        let clipboard = NSPasteboard.general
        let originalChangeCount = clipboard.changeCount
        var interrupted = false
        defer {
            panel.hide(returnFocus: false)
            model.shutdown()
            // This test never writes the pasteboard. If it changed, the user did; leave their clipboard.
            #expect(clipboard.changeCount == originalChangeCount)
            #expect((try? Data(contentsOf: realConfig)) == realBytes)
            #expect((try? Data(contentsOf: paths.configFile)) == scratchBytes)
            #expect(!model.config.remoteControl)
            if !interrupted, idleTime() >= lastIdle, idleTime() >= 45 {
                _ = try? launchServices(["setfront", front])
            }
        }

        func checkIdle() throws {
            let current = idleTime()
            if current < 45 || current + 0.01 < lastIdle {
                interrupted = true
                panel.hide(returnFocus: false)
                throw Failure.interrupted
            }
            lastIdle = current
        }
        func wait(_ condition: () async throws -> Bool) async throws {
            for _ in 0..<240 {
                try checkIdle()
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            Issue.record("Timed out waiting for the panel")
            throw Failure.timeout
        }
        func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
            try checkIdle()
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.panel.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }

        try checkIdle()
        panel.show()
        try await wait { panel.panel.firstResponder is NSTextView }
        try key(4, "hello world")
        try await wait { model.input == "hello world" }
        try key(32, "u", .command)
        try await wait { model.input.isEmpty }

        try key(4, "hello world")
        try await wait { model.input == "hello world" }
        try key(32, "u", .control)
        try await wait { model.input.isEmpty }

        try key(4, "hello world")
        try await wait { model.input == "hello world" }
        try key(13, "w", .control)
        try await wait { model.input == "hello " }
        try key(32, "u", .command)
        try await wait { model.input.isEmpty }

        try await wait { model.catalog.contains("claude-opus-5-5") && model.catalog.contains("gemini-4-argon") }
        let titles = ModelMenu.make(for: model).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Claude Opus 5.5"))
        #expect(titles.contains("Gemini 4 Argon"))
        #expect(titles.contains("Anthropic"))
        #expect(titles.contains("Google"))
        #expect(!titles.contains("Max"))
        #expect(model.modelLabel == "Grok 4.7 · Low")
        #expect(!model.catalog.contains("broken"))

        try key(4, "ping")
        try await wait { model.input == "ping" }
        try key(36, "\r")
        try await wait { model.conversation.turns.last?.answer == "ok" && !model.isWorking }
        try key(53, "\u{1b}")
        try await wait { !panel.isVisible }
    }

    private enum Failure: Error { case interrupted, timeout }
}
