import Foundation

/// The quick-answer sessions Wisp started, newest first, so any of them can be reopened in Ghostty.
public struct SessionHistory: Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// The grok session ID.
        public let id: String
        public var title: String
        public var directory: String
        public var updatedAt: Date
    }

    public private(set) var entries: [Entry] = []
    private let file: URL
    private let limit: Int

    public init(file: URL, limit: Int = 20) {
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

    /// Swaps in the titles Grok Build generated for each session, which read better than the first question.
    public mutating func adoptGrokTitles(grokHome: URL) {
        var changed = false
        for index in entries.indices {
            let entry = entries[index]
            guard let title = GrokSessionStore(grokHome: grokHome).title(of: entry.id, directory: entry.directory),
                title != entry.title
            else { continue }
            entries[index].title = title
            changed = true
        }
        if changed { save() }
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

    /// The generated (or manually set) title from the session's `summary.json`.
    public func title(of sessionID: String, directory: String) -> String? {
        struct Summary: Decodable {
            let generatedTitle: String?

            enum CodingKeys: String, CodingKey {
                case generatedTitle = "generated_title"
            }
        }
        guard let folder = folder(of: sessionID, directory: directory),
            let data = try? Data(contentsOf: folder.appending(path: "summary.json")),
            let title = try? JSONDecoder().decode(Summary.self, from: data).generatedTitle,
            !title.isEmpty
        else { return nil }
        return title
    }

    func folder(of sessionID: String, directory: String) -> URL? {
        let fileManager = FileManager.default
        let direct = sessions.appending(path: Self.encode(directory)).appending(path: sessionID)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        // Grok hashes very long paths, so fall back to looking in every group.
        let groups = (try? fileManager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        return groups.map { $0.appending(path: sessionID) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Grok names each group by percent-encoding the working directory, `/` included.
    static func encode(_ directory: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return directory.addingPercentEncoding(withAllowedCharacters: allowed) ?? directory
    }
}
