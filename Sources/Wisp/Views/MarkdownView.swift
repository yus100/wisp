import SwiftUI
import WispCore

/// Renders an answer from `MarkdownBlock`s; inline styling (bold, code, links) comes from `AttributedString`.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 14)).lineSpacing(2)
        case .heading(let text):
            Text(Self.inline(text)).font(.system(size: 14, weight: .semibold)).padding(.top, 2)
        case .listItem(let text, let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 14)).foregroundStyle(.secondary)
                Text(Self.inline(text)).font(.system(size: 14)).lineSpacing(2)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            Text(Self.inline(text))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .table(let rows):
            TableBlock(rows: rows)
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
