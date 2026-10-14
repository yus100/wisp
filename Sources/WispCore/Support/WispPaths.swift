import Foundation

/// Every location Wisp reads or writes, rooted at one home directory so tests can redirect it.
public struct WispPaths: Equatable, Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static let standard = WispPaths(home: FileManager.default.homeDirectoryForCurrentUser)

    /// `~/.config/wisp`
    public var configDirectory: URL { home.appending(path: ".config/wisp", directoryHint: .isDirectory) }
    /// `~/.config/wisp/config.json`
    public var configFile: URL { configDirectory.appending(path: "config.json") }
    /// `~/Library/Application Support/Wisp`
    public var support: URL { created(home.appending(path: "Library/Application Support/Wisp", directoryHint: .isDirectory)) }
    /// `~/Library/Logs/Wisp`
    public var logs: URL { created(home.appending(path: "Library/Logs/Wisp", directoryHint: .isDirectory)) }
    /// `~/Library/Application Support/Wisp/history.json`
    public var historyFile: URL { support.appending(path: "history.json") }

    /// Grok Build's home: `$GROK_HOME` when the login shell sets it, else `~/.grok`.
    public func grokHome(environment: [String: String]) -> URL {
        if let custom = environment["GROK_HOME"], !custom.isEmpty {
            return URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return home.appending(path: ".grok", directoryHint: .isDirectory)
    }

    /// Expands a leading `~` against this home directory.
    public func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home.path(percentEncoded: false).trimmingSuffix("/") + path.dropFirst()
    }

    /// Replaces this home directory with `~` for display, only where it is a whole path
    /// (so `/Users/al` does not match inside `/Users/alice`).
    public func abbreviate(_ text: String) -> String {
        let home = NSRegularExpression.escapedPattern(for: home.path(percentEncoded: false).trimmingSuffix("/"))
        guard let pattern = try? NSRegularExpression(pattern: home + "(?![A-Za-z0-9._-])") else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    private func created(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
