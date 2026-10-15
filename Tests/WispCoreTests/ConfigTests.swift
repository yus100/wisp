import Foundation
import Testing

@testable import WispCore

@Suite struct ConfigTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-config-\(UUID().uuidString)")
    var file: URL { directory.appending(path: "config.json") }

    @Test func missingFileWritesDefaults() throws {
        let (config, problem) = WispConfig.load(from: file)
        #expect(config == WispConfig())
        #expect(problem == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func partialFileKeepsDefaultsForMissingKeys() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{ "model": "grok-4.7", "ghosttyTarget": "tab" }"#.utf8).write(to: file)
        let (config, problem) = WispConfig.load(from: file)
        #expect(problem == nil)
        #expect(config.model == "grok-4.7")
        #expect(config.ghosttyTarget == .tab)
        #expect(config.hotkey == "option+space")
        #expect(config.reasoningEffort == "low")
        #expect(!config.remoteControl)
        #expect(config.notifyWhenDone)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func notificationsCanBeTurnedOff() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{ "notifyWhenDone": false }"#.utf8).write(to: file)
        #expect(!WispConfig.load(from: file).config.notifyWhenDone)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func invalidFileFallsBackWithMessage() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{ "idleResetMinutes": "soon" }"#.utf8).write(to: file)
        let (config, problem) = WispConfig.load(from: file)
        #expect(config == WispConfig())
        #expect(problem?.contains("idleResetMinutes") == true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Issue #1: the first run wrote the old 1.2 s default into every config file, pinning it.
    @Test func retiredKeysAreDroppedOnLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{ "voiceSilenceSeconds": 1.2, "model": "kept" }"#.utf8).write(to: file)
        let (config, problem) = WispConfig.load(from: file)
        #expect(problem == nil)
        #expect(config.voicePauseSeconds == 2.5)
        #expect(config.model == "kept")
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(rewritten?["voiceSilenceSeconds"] == nil)
        #expect(rewritten?["model"] as? String == "kept")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func readHasNoSideEffects() throws {
        #expect(WispConfig.read(from: file) == .missing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        guard case .invalid(let message) = WispConfig.read(from: file) else {
            Issue.record("expected .invalid")
            return
        }
        #expect(message.contains("invalid JSON"))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func saveWritesThroughSymlinks() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "real.json")
        try WispConfig().save(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        var config = WispConfig()
        config.model = "linked"
        try config.save(to: file)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        #expect(WispConfig.load(from: target).config.model == "linked")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func saveRoundTrips() throws {
        var config = WispConfig()
        config.model = "claude-opus-5-5"
        config.voicePauseSeconds = 0
        try config.save(to: file)
        #expect(WispConfig.load(from: file).config == config)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct PathsTests {
    let paths = WispPaths(home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))

    @Test func expandsAndAbbreviatesHome() {
        #expect(paths.expand("~") == "/Users/someone")
        #expect(paths.expand("~/Documents") == "/Users/someone/Documents")
        #expect(paths.expand("/tmp") == "/tmp")
        #expect(paths.abbreviate("ls /Users/someone/Documents") == "ls ~/Documents")
        #expect(paths.abbreviate("cd /Users/someone && ls /Users/someoneelse") == "cd ~ && ls /Users/someoneelse")
    }

    @Test func grokHomeHonorsEnvironment() {
        #expect(paths.grokHome(environment: [:]).path(percentEncoded: false) == "/Users/someone/.grok/")
        #expect(paths.grokHome(environment: ["GROK_HOME": "/opt/grok"]).path(percentEncoded: false) == "/opt/grok/")
    }
}
