import AppKit
import IOKit
import Testing
import WebKit
import WispCore

@testable import Wisp

@Suite(.serialized) @MainActor
struct LivePanelTests {
    private final class TerminationGuard: NSObject, NSApplicationDelegate {
        var requested = false

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            requested = true
            return .terminateCancel
        }
    }

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
    func liveStreamingHistoryAndCopy() async throws {
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
        let scratch = URL(filePath: "/tmp/wisp-live-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = WispPaths(home: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fixture = try #require(Bundle.module.url(forResource: "answer-agent", withExtension: "py", subdirectory: "Fixtures"))
        let executable = scratch.appending(path: "answer-agent.py")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try ConversationIntegrationTests.partial.write(
            to: scratch.appending(path: "partial.txt"), atomically: true, encoding: .utf8)
        try ConversationIntegrationTests.answer.write(
            to: scratch.appending(path: "answer.txt"), atomically: true, encoding: .utf8)
        var config = WispConfig()
        config.grokPath = executable.path
        config.workingDirectory = scratch.path
        config.launchAtLogin = false
        config.notifyWhenDone = false
        config.remoteControl = false
        try config.save(to: paths.configFile)
        let scratchBytes = try Data(contentsOf: paths.configFile)
        _ = NSApplication.shared
        let previousDelegate = NSApp.delegate
        let termination = TerminationGuard()
        NSApp.delegate = termination
        defer { NSApp.delegate = previousDelegate }
        let model = AppModel(configStore: ConfigStore(file: paths.configFile), paths: paths)
        let panel = PanelController(model: model)
        let clipboard = NSPasteboard.general
        let savedClipboard = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let originalChangeCount = clipboard.changeCount
        var ownChangeCount: Int?
        var interrupted = false
        defer {
            panel.hide(returnFocus: false)
            model.shutdown()
            if let ownChangeCount, clipboard.changeCount == ownChangeCount {
                clipboard.clearContents()
                let items = savedClipboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                clipboard.writeObjects(items)
            }
            #expect((try? Data(contentsOf: realConfig)) == realBytes)
            #expect((try? Data(contentsOf: paths.configFile)) == scratchBytes)
            #expect(!model.config.remoteControl)
            if !interrupted, idleTime() >= lastIdle, idleTime() >= 45 {
                _ = try? launchServices(["setfront", front])
            }
        }
        func checkIdle() throws {
            let current = idleTime()
            if termination.requested || current < 45 || current + 0.01 < lastIdle {
                interrupted = true
                panel.hide(returnFocus: false)
                throw ConversationIntegrationTests.Failure.timeout
            }
            lastIdle = current
        }
        func wait(_ condition: () async throws -> Bool) async throws {
            try await ConversationIntegrationTests.wait {
                try checkIdle()
                return try await condition()
            }
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
        func web() throws -> WKWebView {
            try #require(ConversationIntegrationTests.descendants(panel.hostingView, WKWebView.self).first)
        }
        func stage(_ name: String) {
            FileHandle.standardOutput.write(Data("Native smoke: \(name)\n".utf8))
        }
        try checkIdle()
        stage("show isolated panel")
        panel.show()
        try await wait { panel.panel.firstResponder is NSTextView }
        stage("type and submit")
        try key(0, "Explain policy entropy")
        try await wait { model.input == "Explain policy entropy" }
        try key(36, "\r")
        try await wait { model.conversation.turns.last?.answer == ConversationIntegrationTests.partial }
        try await wait {
            (try? await web().evaluateJavaScript(
                "document.querySelectorAll('.katex').length === 1 && document.body.textContent.includes('sum')")) as? Bool == true
        }
        #expect(model.isWorking)
        stage("partial equation rendered")
        try Data().write(to: scratch.appending(path: "finish"))
        try await wait { !model.isWorking && model.conversation.turns.last?.answer == ConversationIntegrationTests.answer }
        try await wait {
            (try? await web().evaluateJavaScript(
                "document.querySelectorAll('.katex').length === 38 && document.body.textContent.includes('END OF ANSWER')"))
                as? Bool == true
        }
        stage("completed answer rendered; reopen history")
        try key(45, "n", .command)
        try await wait { model.conversation.isEmpty }
        stage("new conversation cleared")
        try key(16, "y", .command)
        try await wait { model.isShowingHistory && panel.panel.firstResponder is NSTextView }
        try await Task.sleep(for: .milliseconds(100))
        stage("history visible with \(model.historyMatches.count) entries")
        try key(0, "entropy")
        stage("history filter: \(model.historyFilter)")
        try await wait { model.historyFilter == "entropy" && model.historyMatches.count == 1 }
        try key(125, "")
        try key(36, "\r")
        try await wait { !model.isShowingHistory && model.conversation.turns.last?.answer == ConversationIntegrationTests.answer }
        try await wait {
            (try? await web().evaluateJavaScript(
                "document.querySelectorAll('.katex').length === 38 && document.querySelectorAll('.katex-error').length === 0"))
                as? Bool == true
        }
        stage("history replay rendered; copy source")
        try #require(clipboard.changeCount == originalChangeCount, "Clipboard changed externally; refusing to overwrite it")
        try key(8, "c", [.command, .shift])
        try await wait {
            if clipboard.changeCount != originalChangeCount,
                clipboard.string(forType: .string) == ConversationIntegrationTests.answer
            {
                ownChangeCount = clipboard.changeCount
                return true
            }
            return false
        }
        #expect(clipboard.string(forType: .string) == ConversationIntegrationTests.answer)
        try key(53, "\u{1b}")
        try await wait { !panel.isVisible }
    }
}
