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

    /// Everything saved, newest first, including sessions that are gone.
    public private(set) var entries: [Entry] = []
    /// Sessions whose folder was missing at the last refresh. They stay saved, so a wrong `GROK_HOME`
    /// cannot erase anything, but are left out of `available`.
    private var missing: Set<String> = []
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
        missing.remove(sessionID)
        entries = Array(entries.prefix(limit))
        save()
    }

    /// The conversations whose Grok Build session still exists (as of the last refresh), newest first.
    public var available: [Entry] {
        entries.filter { !missing.contains($0.id) }
    }

    /// Available entries whose title contains every word of `filter` (ignoring case and accents).
    public func matching(_ filter: String) -> [Entry] {
        let words = filter.split(whereSeparator: \.isWhitespace).map(String.init)
        return available.filter { entry in words.allSatisfy { entry.title.localizedStandardContains($0) } }
    }

    /// Hides entries whose Grok Build session folder is gone (and shows them again if it is back), and
    /// swaps in the titles Grok Build generated, which read better than the first question.
    public mutating func refresh(grokHome: URL) {
        let store = GrokSessionStore(grokHome: grokHome)
        var missing: Set<String> = []
        var retitled = false
        for index in entries.indices {
            guard let folder = store.folder(of: entries[index].id, directory: entries[index].directory) else {
                missing.insert(entries[index].id)
                continue
            }
            if let title = GrokSessionStore.title(in: folder), title != entries[index].title {
                entries[index].title = title
                retitled = true
            }
        }
        self.missing = missing
        if retitled { save() }
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

    /// Whether a running Grok Build terminal session (in Ghostty, say) has the session open, going by the
    /// `active_sessions.json` grok keeps. `grok agent` does not list the sessions it loads.
    public func isOpenInTerminal(_ sessionID: String) -> Bool {
        struct Active: Decodable {
            let sessionID: String
            let pid: Int32
            /// When the process started, in microseconds since 1970, so a reused pid does not count.
            let pidStart: Int64?

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case pid
                case pidStart = "pid_start"
            }
        }
        guard let data = try? Data(contentsOf: grokHome.appending(path: "active_sessions.json")),
            let active = try? JSONDecoder().decode([Active].self, from: data)
        else { return false }
        return active.contains { entry in
            guard entry.sessionID == sessionID, let started = Self.startMicroseconds(of: entry.pid) else { return false }
            return entry.pidStart.map { abs($0 - started) < 1_000_000 } ?? true
        }
    }

    /// When a running process started, or nil if there is no such process.
    static func startMicroseconds(of pid: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }
}
