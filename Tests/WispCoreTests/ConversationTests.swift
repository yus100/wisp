import Foundation
import Testing

@testable import WispCore

@Suite struct ConversationTests {
    let paths = WispPaths(home: URL(filePath: "/Users/me", directoryHint: .isDirectory))

    @Test func streamsTextAndStepsIntoTheRunningTurn() {
        var conversation = Conversation(paths: paths)
        conversation.begin("how big is Documents?")
        #expect(conversation.isWorking)
        conversation.apply(.messageChunk("Let me check."))
        conversation.apply(
            .toolCall(
                ToolCall(
                    id: "t1", title: "run_terminal_command", status: "pending",
                    input: ToolInput(command: "du -sh /Users/me/Documents"))))
        conversation.apply(
            .toolCallUpdate(ToolCallUpdate(id: "t1", title: "Execute `du -sh /Users/me/Documents`", status: "completed")))
        conversation.apply(.thoughtChunk("thinking"))
        conversation.apply(.messageChunk("It is 4 GB."))
        conversation.finish(stopReason: "end_turn", model: "grok-4.7")

        let turn = conversation.turns[0]
        #expect(turn.answer == "Let me check.\n\nIt is 4 GB.")
        #expect(turn.steps == [Turn.Step(id: "t1", title: "Execute `du -sh ~/Documents`", status: .completed)])
        #expect(turn.state == .finished)
        #expect(turn.model == "grok-4.7")
        #expect(!conversation.isWorking)
    }

    @Test func stepTitlesFallBackToArguments() {
        func summary(_ call: ToolCall) -> String { Conversation.summary(of: call, paths: paths) }
        #expect(
            summary(ToolCall(id: "a", title: "run_terminal_command", status: nil, input: ToolInput(command: "ls\n-la")))
                == "Run `ls -la`")
        #expect(summary(ToolCall(id: "b", title: "grep", status: nil, input: ToolInput(query: "TODO"))) == "Search “TODO”")
        #expect(
            summary(ToolCall(id: "c", title: "read_file", status: nil, input: ToolInput(path: "/Users/me/a.txt")))
                == "Read ~/a.txt")
        #expect(summary(ToolCall(id: "d", title: "web_search", status: nil)) == "Web Search")
    }

    @Test func retriesShowANoticeUntilTextArrives() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.apply(.retry(.retrying(attempt: 2, maxRetries: 5)))
        #expect(conversation.turns[0].notice == "The model is busy, retrying (2 of 5)…")
        conversation.apply(.messageChunk("ok"))
        #expect(conversation.turns[0].notice == nil)
    }

    @Test func failuresStickEvenWhenThePromptLaterReturns() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.apply(.retry(.failed(message: "Token expired.", isAuthError: true)))
        conversation.finish(stopReason: "end_turn", model: "grok-4.7")
        #expect(conversation.turns[0].state == .failed("Token expired. Run `grok login` in a terminal, then try again."))
        #expect(conversation.turns[0].model == "grok-4.7")
    }

    @Test func cancelledTurnsAndLateUpdates() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.finish(stopReason: "cancelled", model: nil)
        conversation.apply(.messageChunk("late"))
        #expect(conversation.turns[0].state == .cancelled)
        #expect(conversation.turns[0].answer == "")
    }

    @Test func replayRebuildsSavedTurns() {
        let attached = PromptComposer.compose("what's in it?", attachments: [.file(URL(filePath: "/Users/me/a.txt"))])
        var conversation = Conversation(paths: paths)
        conversation.replay(.userMessageChunk("what is 6*7?", promptIndex: 0))
        conversation.replay(.thoughtChunk("easy"))
        conversation.replay(.messageChunk("42"))
        conversation.replay(.turnCompleted(stopReason: "end_turn"))
        conversation.replay(.userMessageChunk(String(attached.prefix(5)), promptIndex: 1))
        conversation.replay(.userMessageChunk("", promptIndex: 1))  // an image
        conversation.replay(.userMessageChunk(String(attached.dropFirst(5)), promptIndex: 1))
        conversation.replay(.toolCall(ToolCall(id: "t", title: "Read `/Users/me/a.txt`", status: "completed")))
        conversation.replay(.messageChunk("A shopping list."))
        conversation.replay(.turnCompleted(stopReason: "cancelled"))
        conversation.replay(.userMessageChunk("and now?", promptIndex: 2))
        conversation.replay(.messageChunk("Cut off"))
        conversation.endReplay()

        #expect(conversation.turns.map(\.query) == ["what is 6*7?", "what's in it?", "and now?"])
        #expect(conversation.turns.map(\.attachments) == [[], ["a.txt"], []])
        #expect(conversation.turns.map(\.answer) == ["42", "A shopping list.", "Cut off"])
        #expect(conversation.turns[1].steps == [Turn.Step(id: "t", title: "Read `~/a.txt`", status: .completed)])
        #expect(conversation.turns.map(\.state) == [.finished, .cancelled, .finished])
        #expect(!conversation.isWorking)
    }

    @Test func replayWithoutPromptIndexesSplitsQuestionsAtOutput() {
        var conversation = Conversation(paths: paths)
        conversation.replay(.userMessageChunk("part one, ", promptIndex: nil))
        conversation.replay(.userMessageChunk("part two", promptIndex: nil))
        conversation.replay(.messageChunk("ok"))
        conversation.replay(.userMessageChunk("next", promptIndex: nil))
        conversation.endReplay()
        #expect(conversation.turns.map(\.query) == ["part one, part two", "next"])
        #expect(conversation.turns.map(\.state) == [.finished, .finished])
    }

    @Test func liveTurnsIgnoreReplayOnlyUpdates() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.apply(.userMessageChunk("q", promptIndex: 0))
        conversation.apply(.turnCompleted(stopReason: "end_turn"))
        #expect(conversation.turns.count == 1)
        #expect(conversation.isWorking)
    }
}

@Suite struct SessionHistoryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "wisp-history-\(UUID().uuidString)")

    @Test func recordsNewestFirstAndPersists() {
        let file = root.appending(path: "history.json")
        var history = SessionHistory(file: file, limit: 2)
        history.record("a", title: "first", directory: "/Users/me", at: Date(timeIntervalSince1970: 1))
        history.record("b", title: String(repeating: "x", count: 100), directory: "/Users/me", at: Date(timeIntervalSince1970: 2))
        history.record("a", title: "ignored", directory: "/Users/me", at: Date(timeIntervalSince1970: 3))
        history.record("c", title: "third", directory: "/Users/me", at: Date(timeIntervalSince1970: 4))
        #expect(history.entries.map(\.id) == ["c", "a"])
        #expect(history.entries[1].title == "first")
        #expect(SessionHistory(file: file).entries == history.entries)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func keepsTheNewestHundredByDefault() {
        let file = root.appending(path: "history.json")
        var history = SessionHistory(file: file)
        for number in 1...105 {
            history.record("s\(number)", title: "q\(number)", directory: "/Users/me", at: Date(timeIntervalSince1970: 0))
        }
        #expect(SessionHistory.defaultLimit == 100)
        #expect(history.entries.count == 100)
        #expect(history.entries.first?.id == "s105")
        #expect(history.entries.last?.id == "s6")
        #expect(SessionHistory(file: file).entries.count == 100)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func filtersTitlesByEveryWordIgnoringCaseAndAccents() {
        var history = SessionHistory(file: root.appending(path: "history.json"))
        history.record("a", title: "SFO flight booking-window chart", directory: "/Users/me")
        history.record("b", title: "Café near the office", directory: "/Users/me/code")
        history.record("c", title: "Flight delays at SFO", directory: "/Users/me")
        #expect(history.matching("").map(\.id) == ["c", "b", "a"])
        #expect(history.matching("  ").map(\.id) == ["c", "b", "a"])
        #expect(history.matching("sfo").map(\.id) == ["c", "a"])
        #expect(history.matching("chart sfo").map(\.id) == ["a"])
        #expect(history.matching("cafe").map(\.id) == ["b"])
        #expect(history.matching("code").isEmpty)  // titles only, not folders
        try? FileManager.default.removeItem(at: root)
    }

    @Test func refreshDropsMissingSessionsAndAdoptsGrokTitles() throws {
        let grokHome = root.appending(path: ".grok")
        let folder = grokHome.appending(path: "sessions/%2FUsers%2Fme/s1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"generated_title":"Codeword recall test","info":{"id":"s1"}}"#.utf8).write(
            to: folder.appending(path: "summary.json"))
        // grok hashes very long paths, so a session can sit in another group.
        try FileManager.default.createDirectory(
            at: grokHome.appending(path: "sessions/hashed-group/s3"), withIntermediateDirectories: true)

        let file = root.appending(path: "history.json")
        var history = SessionHistory(file: file)
        history.record("s1", title: "remember the codeword", directory: "/Users/me")
        history.record("s2", title: "deleted in grok", directory: "/Users/me")
        history.record("s3", title: "no summary yet", directory: "/Users/me/" + String(repeating: "deep/", count: 60))
        history.refresh(grokHome: grokHome)
        #expect(history.entries.map(\.id) == ["s3", "s1"])
        #expect(history.entries.map(\.title) == ["no summary yet", "Codeword recall test"])
        #expect(SessionHistory(file: file).entries.map(\.title) == ["no summary yet", "Codeword recall test"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func refreshKeepsEverythingWithoutASessionsFolder() {
        var history = SessionHistory(file: root.appending(path: "history.json"))
        history.record("s1", title: "first", directory: "/Users/me")
        history.refresh(grokHome: root.appending(path: "wrong-grok-home"))
        #expect(history.entries.map(\.id) == ["s1"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func encodesDirectoriesLikeGrok() {
        #expect(GrokSessionStore.encode("/Users/stanleyy") == "%2FUsers%2Fstanleyy")
        #expect(GrokSessionStore.encode("/private/tmp/gs-devtest") == "%2Fprivate%2Ftmp%2Fgs-devtest")
    }
}
