import Foundation

/// Block-level Markdown, parsed line by line so a streaming answer renders sensibly at every chunk.
/// Inline styling (bold, code, links) is left to `AttributedString(markdown:)` in the view.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    /// A list item; `marker` is `•` or the item number, `depth` counts two-space indents.
    case listItem(String, marker: String, depth: Int)
    case quote(String)
    /// Fenced code. An unclosed fence (mid-stream) runs to the end of the text.
    case code(String)
    /// Rows of cells, header first, with the `|---|` separator removed.
    case table([[String]])
    case rule

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(tableRows(table))) }
            table.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                table.append(trimmed)
                continue
            }
            flushTable()

            if trimmed.isEmpty {
                flushParagraph()
            } else if let match = trimmed.wholeMatch(of: #/#{1,6}\s+(.*)/#) {
                flushParagraph()
                blocks.append(.heading(String(match.1)))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let match = line.wholeMatch(of: #/(\s*)[-*+]\s+(.*)/#) {
                flushParagraph()
                blocks.append(.listItem(String(match.2), marker: "•", depth: match.1.count / 2))
            } else if let match = line.wholeMatch(of: #/(\s*)(\d+)[.)]\s+(.*)/#) {
                flushParagraph()
                blocks.append(.listItem(String(match.3), marker: "\(match.2).", depth: match.1.count / 2))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }

    static func tableRows(_ lines: [String]) -> [[String]] {
        lines.compactMap { line in
            var row = Substring(line)
            if row.hasPrefix("|") { row = row.dropFirst() }
            if row.hasSuffix("|") { row = row.dropLast() }
            let cells = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let isSeparator = cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
            return isSeparator ? nil : cells
        }
    }
}
