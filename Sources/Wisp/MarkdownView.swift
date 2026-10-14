import SwiftUI

/// Renders the Markdown subset answers use: paragraphs with inline styling, headings, lists,
/// quotes, tables (as monospaced text), and fenced code. Unclosed fences render as code while streaming.
struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case bullet(String, indent: Int, marker: String)
        case quote(String)
        case code(String)
        case table(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 14)).lineSpacing(2)
        case .heading(let text):
            Text(Self.inline(text)).font(.system(size: 14, weight: .semibold)).padding(.top, 2)
        case .bullet(let text, let indent, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 14)).foregroundStyle(.secondary)
                Text(Self.inline(text)).font(.system(size: 14)).lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            Text(Self.inline(text)).font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let code):
            Text(code).font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .table(let table):
            TableBlock(rows: Self.tableRows(table))
        case .rule:
            Divider()
        }
    }

    /// Splits a pipe table into cells, dropping the `|---|` separator row.
    static func tableRows(_ table: String) -> [[String]] {
        table.split(separator: "\n").compactMap { line in
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|") { row.removeLast() }
            let cells = row.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let isSeparator = cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
            return isSeparator ? nil : cells
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))) }
            table.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph(); flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code!.append(line)
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
            } else if let heading = trimmed.firstMatch(of: #/^#{1,6}\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.heading(String(heading.1)))
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = line.firstMatch(of: #/^(\s*)[-*+]\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.bullet(String(item.2), indent: item.1.count / 2, marker: "•"))
            } else if let item = line.firstMatch(of: #/^(\s*)(\d+)[.)]\s+(.*)$/#) {
                flushParagraph()
                blocks.append(.bullet(String(item.3), indent: item.1.count / 2, marker: "\(item.2)."))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(trimmed)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }
}

private struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(MarkdownView.inline(column < row.count ? row[column] : ""))
                            .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                    }
                }
                if index == 0 { Divider() }
            }
        }
        .padding(.vertical, 2)
    }
}
