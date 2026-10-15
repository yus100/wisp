import Foundation

/// A command the agent accepts as a prompt starting with `/`: a built-in such as `/compact`, one of the
/// user's skills, or a saved workflow. grok advertises them with `available_commands_update`.
public struct SlashCommand: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case name, description }

    /// Commands matching what is typed: the input must be `/` plus a partial name, with no space yet.
    /// Name prefixes rank first, then names containing the text, then descriptions containing it;
    /// shorter names first within each group.
    public static func suggestions(for input: String, in commands: [SlashCommand], limit: Int = 6) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(where: \.isWhitespace) else { return [] }
        let query = input.dropFirst().lowercased()
        let ranked = commands.compactMap { command -> (Int, SlashCommand)? in
            let name = command.name.lowercased()
            if query.isEmpty || name.hasPrefix(query) { return (0, command) }
            if name.contains(query) { return (1, command) }
            if command.description.lowercased().contains(query) { return (2, command) }
            return nil
        }
        let sorted = ranked.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1.name.count != rhs.1.name.count { return lhs.1.name.count < rhs.1.name.count }
            return lhs.1.name < rhs.1.name
        }
        let matches = sorted.map(\.1)
        // Once the whole name is typed, there is nothing left to suggest.
        if matches.count == 1, matches[0].name.lowercased() == query { return [] }
        return Array(matches.prefix(limit))
    }
}
