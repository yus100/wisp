import Foundation

/// User settings from `~/.config/wisp/config.json`. Every key is optional in the file; missing keys use the defaults here.
public struct WispConfig: Codable, Equatable, Sendable {
    public enum GhosttyTarget: String, Codable, Sendable {
        case window, tab
    }

    /// Tap to show or hide the panel; hold to talk (release sends).
    public var hotkey = "option+space"
    /// Hands-free voice: opens the panel listening and sends after a pause.
    public var voiceHotkey = "option+shift+space"
    /// Model for quick answers. Empty uses the Grok Build default.
    public var model = ""
    /// Reasoning effort for quick answers. Empty uses the model's default.
    public var reasoningEffort = "low"
    /// Directory quick-answer sessions run in. Home gives the agent the whole file tree.
    public var workingDirectory = "~"
    /// Path to the `grok` binary. Empty searches the login shell's PATH.
    public var grokPath = ""
    /// Start a fresh conversation when the panel opens after this many idle minutes; 0 never resets.
    public var idleResetMinutes = 10.0
    /// Speech-to-text language code.
    public var voiceLanguage = "en"
    /// Hands-free voice sends after this many seconds of silence; 0 waits for the hotkey or Return.
    public var voiceSilenceSeconds = 1.2
    /// Open Grok Build sessions in a new Ghostty window or a new tab of the front window.
    public var ghosttyTarget = GhosttyTarget.window
    /// Extra instructions appended to the quick-answer rules.
    public var extraRules = ""
    /// Accept `Wisp ctl` commands. Off by default: when on, any process running as you can drive the
    /// always-approve agent and the microphone through Wisp's privacy permissions.
    public var remoteControl = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WispConfig()
        hotkey = try container.decode(.hotkey, default: defaults.hotkey)
        voiceHotkey = try container.decode(.voiceHotkey, default: defaults.voiceHotkey)
        model = try container.decode(.model, default: defaults.model)
        reasoningEffort = try container.decode(.reasoningEffort, default: defaults.reasoningEffort)
        workingDirectory = try container.decode(.workingDirectory, default: defaults.workingDirectory)
        grokPath = try container.decode(.grokPath, default: defaults.grokPath)
        idleResetMinutes = try container.decode(.idleResetMinutes, default: defaults.idleResetMinutes)
        voiceLanguage = try container.decode(.voiceLanguage, default: defaults.voiceLanguage)
        voiceSilenceSeconds = try container.decode(.voiceSilenceSeconds, default: defaults.voiceSilenceSeconds)
        ghosttyTarget = try container.decode(.ghosttyTarget, default: defaults.ghosttyTarget)
        extraRules = try container.decode(.extraRules, default: defaults.extraRules)
        remoteControl = try container.decode(.remoteControl, default: defaults.remoteControl)
    }

    /// Reads the config, writing the defaults on first run so every setting is discoverable.
    /// A file that does not parse falls back to the defaults and returns a message to show.
    public static func load(from url: URL) -> (config: WispConfig, problem: String?) {
        guard let data = try? Data(contentsOf: url) else {
            let config = WispConfig()
            try? config.save(to: url)
            return (config, nil)
        }
        do {
            return (try JSONDecoder().decode(WispConfig.self, from: data), nil)
        } catch {
            return (WispConfig(), "\(url.lastPathComponent) has an error (\(describe(error))), so Wisp is using the defaults.")
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            let key = context.codingPath.map(\.stringValue).joined(separator: ".")
            return key.isEmpty ? "invalid JSON" : "bad value for \"\(key)\""
        default:
            return error.localizedDescription
        }
    }
}

extension KeyedDecodingContainer {
    fileprivate func decode<T: Decodable>(_ key: Key, default value: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? value
    }
}
