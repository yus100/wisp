import Foundation

/// One question and its streamed answer.
public struct Turn: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case finished
        case cancelled
        case failed(String)
    }

    /// A tool the agent ran while answering, summarized to one line.
    public struct Step: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable { case running, completed, failed }

        public let id: String
        public var title: String
        public var status: Status
    }

    public let id = UUID()
    public internal(set) var query: String
    /// Labels of what was attached to the question, shown under it.
    public internal(set) var attachments: [String]
    /// The prompt as the agent got it and grok's index for it, when replayed from history.
    var replayedPrompt = ""
    var replayedPromptIndex: Int?
    public internal(set) var answer = ""
    public internal(set) var steps: [Step] = []
    public internal(set) var state = State.running
    /// A transient note such as "retrying", cleared when text arrives.
    public internal(set) var notice: String?
    /// The model that answered, once the turn ends.
    public internal(set) var model: String?
    /// Text after a tool call starts a new paragraph rather than running into the earlier text.
    var startsNewParagraph = false

    public init(query: String, attachments: [String] = []) {
        self.query = query
        self.attachments = attachments
    }

    public var isRunning: Bool { state == .running }
}

/// The turns of one quick-answer session, built by applying the agent's session updates.
public struct Conversation: Equatable, Sendable {
    public private(set) var turns: [Turn] = []
    private let paths: WispPaths

    public init(paths: WispPaths = .standard) {
        self.paths = paths
    }

    public var isEmpty: Bool { turns.isEmpty }
    public var isWorking: Bool { turns.last?.isRunning ?? false }

    public mutating func begin(_ query: String, attachments: [String] = []) {
        turns.append(Turn(query: query, attachments: attachments))
    }

    public mutating func apply(_ update: SessionUpdate) {
        let paths = paths
        updateLast { turn in
            switch update {
            case .messageChunk(let text):
                guard !text.isEmpty else { return }
                if turn.startsNewParagraph, !turn.answer.isEmpty, !turn.answer.hasSuffix("\n\n") {
                    turn.answer += turn.answer.hasSuffix("\n") ? "\n" : "\n\n"
                }
                turn.startsNewParagraph = false
                turn.notice = nil
                turn.answer += text
            case .toolCall(let call):
                let step = Turn.Step(id: call.id, title: Self.summary(of: call, paths: paths), status: Self.status(call.status))
                if let index = turn.steps.firstIndex(where: { $0.id == call.id }) {
                    turn.steps[index] = step
                } else {
                    turn.steps.append(step)
                }
                turn.startsNewParagraph = true
            case .toolCallUpdate(let update):
                guard let index = turn.steps.firstIndex(where: { $0.id == update.id }) else { return }
                if update.status != nil { turn.steps[index].status = Self.status(update.status) }
                if let title = update.title, Self.isDescriptive(title) {
                    turn.steps[index].title = Self.tidy(title, paths: paths)
                }
            case .retry(.retrying(let attempt, let maxRetries)):
                turn.notice = "The model is busy, retrying" + (maxRetries.map { " (\(attempt) of \($0))" } ?? "") + "…"
            case .retry(.exhausted(let reason)):
                turn.notice = nil
                turn.state = .failed(reason)
            case .retry(.failed(let message, let isAuthError)):
                turn.notice = nil
                turn.state = .failed(isAuthError ? "\(message) Run `grok login` in a terminal, then try again." : message)
            case .retry(.other), .thoughtChunk, .availableCommands, .userMessageChunk, .turnCompleted, .other:
                break
            }
        }
    }

    /// Rebuilds the turns `session/load` replays: each question, what streamed for it, and how it ended.
    public mutating func replay(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let text, let promptIndex):
            guard !text.isEmpty else { return }  // an image
            // A question can arrive in several chunks. Without grok's index, a new question starts once the
            // last one has output.
            let sameQuestion = turns.last.map { last in
                last.isRunning
                    && (promptIndex.map { $0 == last.replayedPromptIndex } ?? (last.answer.isEmpty && last.steps.isEmpty))
            }
            if sameQuestion != true {
                endReplay()
                turns.append(Turn(query: "", attachments: []))
                turns[turns.count - 1].replayedPromptIndex = promptIndex
            }
            let index = turns.count - 1
            turns[index].replayedPrompt += text
            (turns[index].query, turns[index].attachments) = PromptComposer.parse(turns[index].replayedPrompt)
        case .turnCompleted(let stopReason):
            finish(stopReason: stopReason, model: nil)
        default:
            apply(update)
        }
    }

    /// Ends a replayed turn that has no `turn_completed`, such as one cut off when the agent stopped.
    public mutating func endReplay() {
        guard let index = turns.indices.last, turns[index].isRunning else { return }
        turns[index].notice = nil
        turns[index].state = .finished
    }

    /// Ends the running turn with the agent's reply to `session/prompt`.
    /// A turn that already failed (for example, retries ran out) keeps its error but still records the model.
    public mutating func finish(stopReason: String?, model: String?) {
        guard let index = turns.indices.last else { return }
        turns[index].notice = nil
        turns[index].model = model
        guard turns[index].isRunning else { return }
        turns[index].state = stopReason == "cancelled" ? .cancelled : .finished
        let turn = turns[index]
        // Commands that open a view in grok's terminal UI (/context, /memory) end silently over ACP.
        if turn.state == .finished, turn.answer.isEmpty, turn.steps.isEmpty, turn.query.hasPrefix("/") {
            let command = turn.query.split(separator: " ").first.map(String.init) ?? turn.query
            turns[index].notice =
                "\(command) showed nothing here. Some commands only work in grok's terminal view; ⌘↩ opens this conversation there."
        }
    }

    public mutating func fail(_ message: String) {
        updateLast { turn in
            turn.notice = nil
            turn.state = .failed(message)
        }
    }

    private mutating func updateLast(_ change: (inout Turn) -> Void) {
        guard !turns.isEmpty, turns[turns.count - 1].isRunning else { return }
        change(&turns[turns.count - 1])
    }

    // MARK: Step summaries

    /// grok's first `tool_call` carries the bare tool name; its later `tool_call_update` carries a readable
    /// title such as "Execute `ls ~`". Until that arrives, describe the call from its arguments.
    static func summary(of call: ToolCall, paths: WispPaths) -> String {
        if let title = call.title, isDescriptive(title) { return tidy(title, paths: paths) }
        if let command = call.input.command { return tidy("Run `\(command)`", paths: paths) }
        if let query = call.input.query { return tidy("Search “\(query)”", paths: paths) }
        if let url = call.input.url { return tidy("Open \(url)", paths: paths) }
        if let path = call.input.path { return tidy("Read \(path)", paths: paths) }
        return (call.title ?? "Tool").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func isDescriptive(_ title: String) -> Bool {
        title.contains(" ")
    }

    private static func tidy(_ text: String, paths: WispPaths) -> String {
        let flat = paths.abbreviate(text).replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    private static func status(_ text: String?) -> Turn.Step.Status {
        switch text {
        case "completed": .completed
        case "failed": .failed
        default: .running
        }
    }
}
