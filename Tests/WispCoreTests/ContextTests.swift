import Foundation
import Testing

@testable import WispCore

@Suite struct SlashCommandTests {
    let commands = [
        SlashCommand(name: "compact", description: "Compress conversation history"),
        SlashCommand(name: "context", description: "Show context window usage"),
        SlashCommand(name: "deep-research", description: "Research with parallel agents"),
        SlashCommand(name: "dd-cli-usage", description: "Order food from DoorDash"),
        SlashCommand(name: "review", description: "Run a reviewer subagent"),
        SlashCommand(name: "code-review", description: "Strict maintainability review"),
    ]

    @Test func decodesTheAdvertisedList() throws {
        let note = try JSONDecoder().decode(
            SessionNotification.self,
            from: Data(
                """
                {"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[
                  {"name":"compact","description":"Compress history","input":null},
                  {"name":"review"},
                  {"description":"no name, skipped"}]}}
                """.utf8))
        #expect(
            note.update
                == .availableCommands([
                    SlashCommand(name: "compact", description: "Compress history"), SlashCommand(name: "review", description: ""),
                ]))
    }

    @Test func prefixMatchesComeFirst() {
        #expect(SlashCommand.suggestions(for: "/co", in: commands).map(\.name) == ["compact", "context", "code-review"])
        #expect(SlashCommand.suggestions(for: "/review", in: commands).map(\.name) == ["review", "code-review"])
    }

    @Test func descriptionsMatchToo() {
        #expect(SlashCommand.suggestions(for: "/door", in: commands).map(\.name) == ["dd-cli-usage"])
    }

    @Test func noSuggestionsOnceTheCommandIsTypedOrHasArguments() {
        #expect(SlashCommand.suggestions(for: "/compact", in: commands).isEmpty)
        #expect(SlashCommand.suggestions(for: "/deep-research what is", in: commands).isEmpty)
        #expect(SlashCommand.suggestions(for: "hello", in: commands).isEmpty)
        #expect(SlashCommand.suggestions(for: "/", in: commands, limit: 3).count == 3)
    }
}

@Suite struct AttachmentTests {
    @Test func labelsAndKinds() {
        #expect(Attachment.file(URL(filePath: "/tmp/Shot.PNG")).kind == .image)
        #expect(Attachment.file(URL(filePath: "/tmp/report.pdf")).kind == .file)
        #expect(Attachment.file(URL(filePath: "/tmp/report.pdf")).label == "report.pdf")
        #expect(Attachment(url: URL(filePath: "/tmp/w.png"), kind: .window("Safari")).label == "Safari window")
    }

    @Test func promptListsEveryAttachment() {
        let prompt = PromptComposer.compose(
            " what's wrong here? ",
            attachments: [
                Attachment(url: URL(filePath: "/tmp/w.png"), kind: .window("Xcode")),
                .file(URL(filePath: "/Users/me/notes.txt")),
            ])
        #expect(
            prompt == """
                what's wrong here?

                Attached (open these with your file tools):
                - Screenshot of the Xcode window the user was looking at: /tmp/w.png (an image; view it)
                - File: /Users/me/notes.txt
                """)
    }

    @Test func plainQuestionsAndAttachmentOnlyQuestions() {
        #expect(PromptComposer.compose("hi", attachments: []) == "hi")
        #expect(
            PromptComposer.compose("", attachments: [.file(URL(filePath: "/a.png"))]).hasPrefix("Take a look at what I attached.")
        )
    }

    @Test func turnsRememberAttachmentLabels() {
        var conversation = Conversation()
        conversation.begin("what is this?", attachments: ["Safari window"])
        #expect(conversation.turns[0].attachments == ["Safari window"])
    }
}

@Suite struct TextPreviewTests {
    @Test func stripsMarkdownToOneLine() {
        let answer = """
            ## Result

            The **answer** is `42`, see [the docs](https://example.com).

            - first_item
            - second

            | a | b |
            |---|---|
            | 1 | 2 |
            """
        #expect(
            TextPreview.line(answer, limit: 200)
                == "Result The answer is 42, see the docs. first_item second a b 1 2")
    }

    @Test func cutsAtAWord() {
        #expect(TextPreview.line("one two three four", limit: 10) == "one two…")
        #expect(TextPreview.line("short", limit: 10) == "short")
    }
}
