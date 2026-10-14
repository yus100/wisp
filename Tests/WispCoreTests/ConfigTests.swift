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

    @Test func saveRoundTrips() throws {
        var config = WispConfig()
        config.model = "claude-opus-5-5"
        config.voiceSilenceSeconds = 0
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
    }

    @Test func grokHomeHonorsEnvironment() {
        #expect(paths.grokHome(environment: [:]).path(percentEncoded: false) == "/Users/someone/.grok/")
        #expect(paths.grokHome(environment: ["GROK_HOME": "/opt/grok"]).path(percentEncoded: false) == "/opt/grok/")
    }
}
