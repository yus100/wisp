import Foundation

/// The quick-answer sessions Wisp started, newest first, so any of them can be reopened in the panel or
/// in Ghostty. Entries only point at Grok Build sessions; the conversations themselves stay in grok's files.
public struct SessionHistory: Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// The grok session ID.
        public let id: String
        public var title: String
        public var directory: String
        public var updatedAt: Date
    }

    public static let defaultLimit = 100

    public private(set) var entries: [Entry] = []
    private let file: URL
    private let limit: Int

    public init(file: URL, limit: Int = defaultLimit) {
        self.file = file
        self.limit = limit
        if let data = try? Data(contentsOf: file), let saved = try? Self.decoder.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Moves a session to the top, adding it with `title` if it is new.
    public mutating func record(_ sessionID: String, title: String, directory: String, at date: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.id == sessionID }) {
            var entry = entries.remove(at: index)
            entry.updatedAt = date
            entries.insert(entry, at: 0)
        } else {
            let short = title.count > 70 ? String(title.prefix(69)) + "…" : title
            entries.insert(Entry(id: sessionID, title: short, directory: directory, updatedAt: date), at: 0)
        }
        entries = Array(entries.prefix(limit))
        save()
    }

    /// Entries whose title contains every word of `filter` (ignoring case and accents), newest first.
    public func matching(_ filter: String) -> [Entry] {
        let words = filter.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in words.allSatisfy { entry.title.localizedStandardContains($0) } }
    }

    /// Drops entries whose Grok Build session folder is gone and swaps in the titles Grok Build generated,
    /// which read better than the first question. Without a sessions folder at all (`grokHome` is
    /// probably wrong), nothing is dropped.
    public mutating func refresh(grokHome: URL) {
        let store = GrokSessionStore(grokHome: grokHome)
        let canPrune = FileManager.default.fileExists(atPath: store.sessions.path)
        var refreshed: [Entry] = []
        for var entry in entries {
            guard let folder = store.folder(of: entry.id, directory: entry.directory) else {
                if !canPrune { refreshed.append(entry) }
                continue
            }
            if let title = GrokSessionStore.title(in: folder) { entry.title = title }
            refreshed.append(entry)
        }
        guard refreshed != entries else { return }
        entries = refreshed
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encoder.encode(entries).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Read-only access to Grok Build's session folders (`~/.grok/sessions/<encoded cwd>/<id>/`).
public struct GrokSessionStore: Sendable {
    let grokHome: URL

    public init(grokHome: URL) {
        self.grokHome = grokHome
    }

    var sessions: URL { grokHome.appending(path: "sessions", directoryHint: .isDirectory) }

    /// The generated (or manually set) title from a session folder's `summary.json`.
    static func title(in folder: URL) -> String? {
        struct Summary: Decodable {
            let generatedTitle: String?

            enum CodingKeys: String, CodingKey {
                case generatedTitle = "generated_title"
            }
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "summary.json")),
            let title = try? JSONDecoder().decode(Summary.self, from: data).generatedTitle,
            !title.isEmpty
        else { return nil }
        return title
    }

    func folder(of sessionID: String, directory: String) -> URL? {
        let fileManager = FileManager.default
        let direct = sessions.appending(path: Self.encode(directory)).appending(path: sessionID)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        // grok hashes very long paths, so fall back to looking in every group.
        let groups = (try? fileManager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        return groups.map { $0.appending(path: sessionID) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// grok names each group by percent-encoding the working directory, `/` included.
    static func encode(_ directory: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return directory.addingPercentEncoding(withAllowedCharacters: allowed) ?? directory
    }
}
