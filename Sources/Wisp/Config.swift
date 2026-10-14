import Foundation

/// User settings, read from `~/.config/wisp/config.json`. Missing keys fall back to defaults.
struct AppConfig: Codable {
    /// Tap to show/hide the panel; hold to talk (release sends).
    var hotkey = "option+space"
    /// Hands-free voice: opens the panel listening and sends after you stop talking.
    var voiceHotkey = "option+shift+space"
    /// Model for quick answers. Empty uses your Grok Build default.
    var model = ""
    /// Reasoning effort for quick answers (minimal, low, medium, high, xhigh). Empty uses your default.
    var reasoningEffort = "low"
    /// Where quick-answer sessions run. Home gives the agent your whole file tree.
    var workingDirectory = "~"
    /// Path to the grok binary. Empty searches your login-shell PATH.
    var grokPath = ""
    /// Start a fresh conversation when the panel opens after this many idle minutes. 0 keeps it forever.
    var idleResetMinutes = 10.0
    /// Speech-to-text language code.
    var voiceLanguage = "en"
    /// Hands-free voice sends after this many seconds of silence. 0 waits for the hotkey or Return.
    var voiceSilenceSeconds = 1.2
    /// "window" or "tab" for sessions opened in Ghostty.
    var ghosttyTarget = "window"
    /// Extra instructions appended to the quick-answer rules.
    var extraRules = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        voiceHotkey = try c.decodeIfPresent(String.self, forKey: .voiceHotkey) ?? d.voiceHotkey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? d.reasoningEffort
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? d.workingDirectory
        grokPath = try c.decodeIfPresent(String.self, forKey: .grokPath) ?? d.grokPath
        idleResetMinutes = try c.decodeIfPresent(Double.self, forKey: .idleResetMinutes) ?? d.idleResetMinutes
        voiceLanguage = try c.decodeIfPresent(String.self, forKey: .voiceLanguage) ?? d.voiceLanguage
        voiceSilenceSeconds = try c.decodeIfPresent(Double.self, forKey: .voiceSilenceSeconds) ?? d.voiceSilenceSeconds
        ghosttyTarget = try c.decodeIfPresent(String.self, forKey: .ghosttyTarget) ?? d.ghosttyTarget
        extraRules = try c.decodeIfPresent(String.self, forKey: .extraRules) ?? d.extraRules
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wisp")
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, writing a default file on first run so the settings are discoverable.
    static func load() -> (AppConfig, String?) {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            let config = AppConfig()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(config) {
                try? data.write(to: url)
            }
            return (config, nil)
        }
        do {
            return (try JSONDecoder().decode(AppConfig.self, from: data), nil)
        } catch {
            return (AppConfig(), "Could not read \(url.path): \(error.localizedDescription). Using defaults.")
        }
    }

    var expandedWorkingDirectory: String {
        (workingDirectory as NSString).expandingTildeInPath
    }
}

enum AppPaths {
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logs: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wisp")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Appends a timestamped line to the app log.
func appLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let url = AppPaths.logs.appendingPathComponent("app.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
