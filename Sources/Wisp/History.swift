import Foundation

/// Recent quick-answer sessions, so any of them can be reopened as a full Grok Build session.
final class HistoryStore {
    struct Entry: Codable, Identifiable {
        let id: String  // grok session ID
        var title: String
        var cwd: String
        var updatedAt: Date
    }

    private(set) var entries: [Entry] = []
    private let url = AppPaths.support.appendingPathComponent("history.json")
    private let limit = 20

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func touch(sessionId: String, title: String, cwd: String) {
        if let index = entries.firstIndex(where: { $0.id == sessionId }) {
            var entry = entries.remove(at: index)
            entry.updatedAt = Date()
            entries.insert(entry, at: 0)
        } else {
            let short = title.count > 70 ? String(title.prefix(69)) + "…" : title
            entries.insert(Entry(id: sessionId, title: short, cwd: cwd, updatedAt: Date()), at: 0)
        }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
