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
        conversation.apply(.toolCall(ToolCall(id: "t1", title: "run_terminal_command", status: "pending", input: ToolInput(command: "du -sh /Users/me/Documents"))))
        conversation.apply(.toolCallUpdate(ToolCallUpdate(id: "t1", title: "Execute `du -sh /Users/me/Documents`", status: "completed")))
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
        #expect(summary(ToolCall(id: "a", title: "run_terminal_command", status: nil, input: ToolInput(command: "ls\n-la"))) == "Run `ls -la`")
        #expect(summary(ToolCall(id: "b", title: "grep", status: nil, input: ToolInput(query: "TODO"))) == "Search “TODO”")
        #expect(summary(ToolCall(id: "c", title: "read_file", status: nil, input: ToolInput(path: "/Users/me/a.txt"))) == "Read ~/a.txt")
        #expect(summary(ToolCall(id: "d", title: "web_search", status: nil)) == "Web Search")
    }

    @Test func retriesShowANoticeUntilTextArrives() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.apply(.retry(.retrying(attempt: 2, maxRetries: 5)))
        #expect(conversation.turns[0].notice == "Grok is busy, retrying (2 of 5)…")
        conversation.apply(.messageChunk("ok"))
        #expect(conversation.turns[0].notice == nil)
    }

    @Test func failuresStickEvenWhenThePromptLaterReturns() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.apply(.retry(.failed(message: "Token expired.", isAuthError: true)))
        conversation.finish(stopReason: "end_turn", model: nil)
        #expect(conversation.turns[0].state == .failed("Token expired. Run `grok login` in a terminal, then try again."))
    }

    @Test func cancelledTurnsAndLateUpdates() {
        var conversation = Conversation(paths: paths)
        conversation.begin("q")
        conversation.finish(stopReason: "cancelled", model: nil)
        conversation.apply(.messageChunk("late"))
        #expect(conversation.turns[0].state == .cancelled)
        #expect(conversation.turns[0].answer == "")
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

    @Test func adoptsGrokGeneratedTitles() throws {
        let grokHome = root.appending(path: ".grok")
        let folder = grokHome.appending(path: "sessions/%2FUsers%2Fme/s1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"generated_title":"Codeword recall test","info":{"id":"s1"}}"#.utf8).write(to: folder.appending(path: "summary.json"))

        var history = SessionHistory(file: root.appending(path: "history.json"))
        history.record("s1", title: "remember the codeword", directory: "/Users/me")
        history.record("s2", title: "no summary yet", directory: "/Users/me")
        history.adoptGrokTitles(grokHome: grokHome)
        #expect(history.entries.map(\.title) == ["no summary yet", "Codeword recall test"])
        try? FileManager.default.removeItem(at: root)
    }

    @Test func encodesDirectoriesLikeGrok() {
        #expect(GrokSessionStore.encode("/Users/stanleyy") == "%2FUsers%2Fstanleyy")
        #expect(GrokSessionStore.encode("/private/tmp/gs-devtest") == "%2Fprivate%2Ftmp%2Fgs-devtest")
    }
}
