import Testing

@testable import WispCore

@Suite struct MarkdownTests {
    @Test func paragraphsHeadingsAndLists() {
        let blocks = MarkdownBlock.parse("""
            # Title
            First line
            second line

            - one
              - nested
            2. two
            > quoted
            ---
            """)
        #expect(blocks == [
            .heading("Title"),
            .paragraph("First line\nsecond line"),
            .listItem("one", marker: "•", depth: 0),
            .listItem("nested", marker: "•", depth: 1),
            .listItem("two", marker: "2.", depth: 0),
            .quote("quoted"),
            .rule,
        ])
    }

    @Test func tablesDropTheSeparatorRow() {
        let blocks = MarkdownBlock.parse("""
            | Name | Size |
            |---|:--:|
            | a | 1 |
            """)
        #expect(blocks == [.table([["Name", "Size"], ["a", "1"]])])
    }

    @Test func codeFencesKeepContentVerbatim() {
        let blocks = MarkdownBlock.parse("""
            Before
            ```swift
            let x = 1
              # not a heading
            ```
            After
            """)
        #expect(blocks == [.paragraph("Before"), .code("let x = 1\n  # not a heading"), .paragraph("After")])
    }

    @Test func unclosedFenceRendersAsCodeWhileStreaming() {
        #expect(MarkdownBlock.parse("```\nlet x") == [.code("let x")])
    }
}
