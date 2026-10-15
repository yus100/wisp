import Foundation

/// One line of plain text from a Markdown answer, for notifications and other short previews.
public enum TextPreview {
    private static let rules: [(pattern: String, replacement: String)] = [
        (#"(?m)^\s*\|?[\s:|-]*-{3,}[\s:|-]*$"#, ""),  // table separator rows and rules
        (#"(?m)^\s*```.*$"#, ""),  // code fences
        (#"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, ""),  // headings, quotes, list markers
        (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),  // links and images keep their text
        (#"\*\*|__|`"#, ""),  // bold and code markers
        (#"\|"#, " "),  // table cells
    ]

    public static func line(_ markdown: String, limit: Int) -> String {
        var text = markdown
        for rule in rules {
            text = text.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        let plain = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard plain.count > limit else { return plain }
        let cut = plain.prefix(limit)
        let atWord = cut.range(of: " ", options: .backwards).map { cut[..<$0.lowerBound] } ?? cut
        return atWord + "…"
    }
}
