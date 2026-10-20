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

    @Test func anUpdateWithoutAListDecodesAsEmpty() throws {
        let note = try JSONDecoder().decode(
            SessionNotification.self,
            from: Data(#"{"sessionId":"s","update":{"sessionUpdate":"available_commands_update"}}"#.utf8))
        #expect(note.update == .availableCommands([]))
    }

    @Test func theCachedListRoundTrips() throws {
        let decoded = try JSONDecoder().decode([SlashCommand].self, from: JSONEncoder().encode(commands))
        #expect(decoded == commands)
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

    @Test func foldersAreRecognizedFromTheDiskOrTheURL() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wisp-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bare = URL(filePath: folder.path, directoryHint: .notDirectory)
        #expect(Attachment.file(bare).kind == .folder)
        #expect(Attachment.file(URL(filePath: "/missing/Photos.png/", directoryHint: .isDirectory)).kind == .folder)
        let attachment = Attachment.file(URL(filePath: "/Users/me/site/", directoryHint: .isDirectory))
        #expect(attachment.label == "site")
        #expect(PromptComposer.compose("tidy this", attachments: [attachment]).hasSuffix("- Folder: /Users/me/site"))
    }

    @Test func plainQuestionsAndAttachmentOnlyQuestions() {
        #expect(PromptComposer.compose("hi", attachments: []) == "hi")
        #expect(
            PromptComposer.compose("", attachments: [.file(URL(filePath: "/a.png"))]).hasPrefix("Take a look at what I attached.")
        )
    }

    @Test func composedPromptsSplitBackIntoQuestionAndLabels() {
        let attachments = [
            Attachment(url: URL(filePath: "/tmp/w 1.png"), kind: .window("Google Chrome")),
            Attachment(url: URL(filePath: "/tmp/Pasted image.png"), kind: .image),
            .file(URL(filePath: "/Users/me/notes.txt")),
            Attachment(url: URL(filePath: "/Users/me/site"), kind: .folder),
        ]
        let parsed = PromptComposer.parse(PromptComposer.compose("what's wrong?\n\nsee below", attachments: attachments))
        #expect(parsed.question == "what's wrong?\n\nsee below")
        #expect(parsed.attachments == attachments.map(\.label))
        #expect(parsed.attachments == ["Google Chrome window", "Pasted image.png", "notes.txt", "site"])
    }

    @Test func otherPromptsParseWhole() {
        #expect(PromptComposer.parse("hi") == ("hi", []))
        let lookalike = "q\n\nAttached (open these with your file tools):\n- something else"
        #expect(PromptComposer.parse(lookalike) == (lookalike, []))
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

@Suite struct SilentCommandTests {
    @Test func silentSlashCommandExplainsItself() {
        var conversation = Conversation(paths: WispPaths(home: URL(filePath: "/Users/me", directoryHint: .isDirectory)))
        conversation.begin("/context")
        conversation.finish(stopReason: "end_turn", model: nil)
        #expect(conversation.turns[0].notice?.hasPrefix("/context showed nothing here.") == true)
    }

    @Test func answeredOrOrdinaryTurnsGetNoNotice() {
        var conversation = Conversation(paths: WispPaths(home: URL(filePath: "/Users/me", directoryHint: .isDirectory)))
        conversation.begin("plain question")
        conversation.finish(stopReason: "end_turn", model: nil)
        #expect(conversation.turns[0].notice == nil)
        conversation.begin("/context")
        conversation.finish(stopReason: "cancelled", model: nil)
        #expect(conversation.turns[1].notice == nil)
    }
}
