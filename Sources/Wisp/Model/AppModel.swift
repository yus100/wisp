import AppKit
import WispCore

/// A message in the panel footer, optionally with a button that opens a settings page.
struct Notice: Equatable {
    var text: String
    var actionTitle: String?
    var actionURL: URL?

    init(_ text: String, actionTitle: String? = nil, actionURL: URL? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.actionURL = actionURL
    }
}

/// The panel's state and everything it can do: one quick-answer conversation backed by a Grok Build
/// session, the history of earlier ones, voice input, model choice, and hand-off to Ghostty.
@MainActor
final class AppModel: ObservableObject {
    @Published var input = "" {
        // Typing changes the suggestion list, so the highlight starts over at the best match.
        didSet { if input != oldValue { selectedSuggestion = 0 } }
    }
    @Published private(set) var conversation: Conversation
    @Published var notice: Notice?
    @Published private(set) var catalog = ModelCatalog()
    @Published private(set) var isHandingOff = false
    /// Bumped whenever the input field should take focus.
    @Published private(set) var focusRequest = 0
    /// Files, images, and window screenshots going with the next question.
    @Published var attachments: [Attachment] = []
    /// Slash commands grok accepts (built-ins, skills, workflows), cached between launches.
    @Published var commands: [SlashCommand] = []
    /// The highlighted row of the slash-command suggestions.
    @Published var selectedSuggestion = 0
    /// The app that was in front when the panel opened; "Attach Window" captures its window.
    var contextApp: NSRunningApplication?
    /// An answer finished; the delegate notifies if the panel is hidden. Not called for hand-offs.
    var onAnswerFinished: ((Turn) -> Void)?
    /// Bumped when the question is sent or the conversation starts over, so a window capture that
    /// finishes afterwards is dropped instead of joining the next question.
    var attachmentGeneration = 0
    var isCapturingWindow = false
    /// An answer finished while the panel was closed; cleared when it opens. Shown in the menu bar.
    @Published var answerWaiting = false
    /// The saved conversations are listed in place of the current one (⌘Y).
    @Published private(set) var isShowingHistory = false
    /// What is typed into the search field while the history list shows.
    @Published var historyFilter = "" {
        didSet { if historyFilter != oldValue { selectedHistoryEntry = 0 } }
    }
    /// The highlighted row of the history list.
    @Published private(set) var selectedHistoryEntry = 0
    /// A saved conversation being loaded back into the panel.
    @Published private(set) var reopening: SessionHistory.Entry?

    let voice = VoiceController()
    @Published private(set) var history: SessionHistory
    private(set) var sessionID: String?
    /// The folder the session runs in; a reopened one keeps the folder it was started in.
    private var sessionDirectory: String?

    /// Hide the panel (after a hand-off opens Ghostty).
    var onRequestHide: (() -> Void)?

    private let configStore: ConfigStore
    private let host: AgentHost
    let paths: WispPaths
    private var lastActivity = Date()
    private var promptTask: Task<Void, Never>?
    private var voiceBaseText = ""
    /// Identifies the current conversation, so work that outlives it cannot touch its replacement.
    private var conversationID = UUID()
    /// ⌘. arrived before the turn's session existed; the turn stops as soon as it does.
    private var stopRequested = false
    /// A `session/load` in flight. Follow-ups wait for it, and the history it replays is ignored.
    private var reattaching: Task<Void, Never>?
    private var ignoringUpdates = false
    /// Identifies the latest reopen from history; clearing it abandons that reopen.
    private var reopenAttempt: UUID?
    private var reopenTask: Task<Void, Never>?
    /// The turns `session/load` replays for the conversation being reopened.
    private var replayed: Conversation

    init(configStore: ConfigStore, paths: WispPaths = .standard) {
        self.configStore = configStore
        self.paths = paths
        host = AgentHost(config: configStore.config, paths: paths)
        conversation = Conversation(paths: paths)
        replayed = Conversation(paths: paths)
        history = SessionHistory(file: paths.historyFile)
        commands = Self.loadCommands(from: paths.commandsFile)
        host.onSessionUpdate = { [weak self] in self?.apply($0) }
        host.onCatalogChange = { [weak self] in self?.catalog = $0 }
        host.onUnexpectedExit = { [weak self] in self?.agentDied(status: $0) }
        configureVoice()
    }

    var config: WispConfig { configStore.config }
    var isWorking: Bool { conversation.isWorking }

    // MARK: Lifecycle

    /// Starts the agent and resolves the shell environment in the background, so the first question is fast.
    func warmUp() {
        Task {
            do {
                _ = try await host.running()
            } catch {
                notice = Notice(error.localizedDescription)
            }
        }
    }

    func configDidChange(from old: WispConfig, to new: WispConfig) {
        if host.apply(new), sessionID != nil {
            // The restarted agent has none of the old sessions loaded; the old one stays in the history.
            newConversation()
        }
        voice.language = new.voiceLanguage
        voice.pauseSeconds = new.voicePauseSeconds
        if old.model != new.model || old.reasoningEffort != new.reasoningEffort {
            applyModelSettingsToSession()
        }
    }

    func panelWillOpen() {
        // Coming back to an answer that finished while the panel was closed must not start over.
        let returningToAnswer = answerWaiting
        answerWaiting = false
        if returningToAnswer { lastActivity = Date() }
        if !returningToAnswer, config.idleResetMinutes > 0, !conversation.isEmpty, !isWorking, !voice.isActive,
            !isHandingOff, Date().timeIntervalSince(lastActivity) > config.idleResetMinutes * 60
        {
            newConversation()
        }
        pruneOldAttachments()
        Task {
            let environment = await host.environment()
            GrokCredentials.prefetch(
                environment: environment, grokHome: host.grokHome, grok: host.grokExecutable(in: environment))
            _ = try? await host.running()
        }
    }

    func focusInput() {
        focusRequest += 1
    }

    func shutdown() {
        voice.cancel()
        host.shutdown()
    }

    func restartAgent() {
        newConversation()
        host.restart()
    }

    /// Shows sample content without touching the agent; used to render the README screenshots.
    func showSample(_ conversation: Conversation, catalog: ModelCatalog) {
        self.conversation = conversation
        self.catalog = catalog
    }

    // MARK: Conversation

    /// `quiet`: the delegate is not told when it finishes (a hand-off, where the user has moved on to Ghostty).
    func submit(_ text: String? = nil, quiet: Bool = false) {
        let typed = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !attachments.isEmpty, !isHandingOff else { return }
        if voice.isActive { voice.cancel() }
        guard !isWorking else {
            notice = Notice("Still answering. Press ⌘. to stop it first.")
            return
        }
        closeHistory()
        let query = typed.isEmpty ? "Take a look at what I attached." : typed
        let prompt = PromptComposer.compose(typed, attachments: attachments)
        input = ""
        notice = nil
        stopRequested = false
        conversation.begin(query, attachments: attachments.map(\.label))
        attachments = []
        attachmentGeneration += 1
        let turnID = conversation.turns.last?.id
        let conversationID = conversationID
        lastActivity = Date()
        promptTask = Task {
            defer { lastActivity = Date() }
            do {
                let (agent, session) = try await activeSession(for: conversationID)
                history.record(
                    session, title: conversation.turns.first?.query ?? query,
                    directory: sessionDirectory ?? host.workingDirectory)
                if stopRequested {
                    stopRequested = false
                    conversation.finish(stopReason: "cancelled", model: nil)
                    return
                }
                let result = try await agent.prompt(prompt, in: session)
                guard conversation.turns.last?.id == turnID else { return }
                conversation.finish(stopReason: result.stopReason, model: result.modelID)
                host.refreshCatalog()
                if !quiet, let turn = conversation.turns.last, turn.state == .finished { onAnswerFinished?(turn) }
            } catch {
                guard conversation.turns.last?.id == turnID, !(error is CancellationError) else { return }
                conversation.fail(error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isWorking else { return }
        guard let sessionID else {
            stopRequested = true
            return
        }
        Task { try? await host.running().cancel(sessionID) }
    }

    func newConversation() {
        voice.cancel()
        promptTask?.cancel()
        if let sessionID {
            if isWorking { Task { try? await host.running().cancel(sessionID) } }
            Task { try? await host.running().close(sessionID) }
        }
        conversationID = UUID()
        stopRequested = false
        sessionID = nil
        sessionDirectory = nil
        conversation = Conversation(paths: paths)
        attachments = []
        attachmentGeneration += 1
        input = ""
        notice = nil
        isShowingHistory = false
        historyFilter = ""
        abandonReopen()
        lastActivity = Date()
        focusRequest += 1
    }

    func copyLastAnswer() {
        guard let answer = conversation.turns.last?.answer, !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        notice = Notice("Copied the answer.")
    }

    private func apply(_ notification: SessionNotification) {
        // Commands are the same for every session, and the list arrives before session/new returns.
        if case .availableCommands(let list) = notification.update {
            updateCommands(list)
            return
        }
        if let reopening, notification.sessionId == reopening.id {
            replayed.replay(notification.update)
            return
        }
        guard !ignoringUpdates, notification.sessionId == sessionID else { return }
        conversation.apply(notification.update)
    }

    /// The current session, creating it (with model settings applied) on first use. Throws
    /// `CancellationError` if the conversation was replaced while the session was being created.
    private func activeSession(for conversation: UUID) async throws -> (GrokAgent, String) {
        if let reattaching { await reattaching.value }
        let agent = try await host.running()
        guard conversationID == conversation else { throw CancellationError() }
        if let sessionID { return (agent, sessionID) }
        let directory = host.workingDirectory
        let rules = QuickAnswerRules.text(
            workingDirectory: directory, ghosttyScript: Self.ghosttyScript.path, extra: config.extraRules)
        let session = try await agent.newSession(in: directory, rules: rules).sessionId
        guard conversationID == conversation else {
            await agent.close(session)
            throw CancellationError()
        }
        sessionID = session
        sessionDirectory = directory
        await applyModelSettings(to: session, on: agent)
        return (agent, session)
    }

    /// Loads a saved session into the agent. grok replays its history as updates, which must not
    /// land in a running turn, so updates are ignored until the load returns (they all arrive before it).
    private func reattach(_ session: String, in directory: String, on agent: GrokAgent) async throws {
        ignoringUpdates = true
        defer { ignoringUpdates = false }
        try await agent.load(session, in: directory)
        await applyModelSettings(to: session, on: agent)
    }

    /// The agent crashed: fail the running turn, then re-attach the session on a fresh agent so
    /// follow-ups keep their context.
    private func agentDied(status: Int32) {
        if isWorking { conversation.fail("The agent stopped unexpectedly (status \(status)). Ask again to continue.") }
        guard let session = sessionID else { return }
        let directory = sessionDirectory ?? host.workingDirectory
        reattaching = Task {
            defer { reattaching = nil }
            do {
                try await reattach(session, in: directory, on: try await host.running())
            } catch {
                if sessionID == session { sessionID = nil }
                notice = Notice("The agent restarted, so follow-ups start a new session.")
            }
        }
    }

    // MARK: Model and effort

    var effectiveModelID: String? { config.model.isEmpty ? catalog.defaultModelID : config.model }

    var modelLabel: String {
        guard let model = effectiveModelID else { return "Default model" }
        let name = catalog.name(of: model)
        return config.reasoningEffort.isEmpty ? name : "\(name) · \(Self.effortLabel(config.reasoningEffort))"
    }

    static func effortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    func selectModel(_ modelID: String) {
        updateConfig { config in
            config.model = modelID
            config.reasoningEffort = catalog.effort(config.reasoningEffort, adjustedFor: modelID)
        }
    }

    func selectEffort(_ effort: String) {
        updateConfig { $0.reasoningEffort = effort }
    }

    func toggleLaunchAtLogin() {
        updateConfig { $0.launchAtLogin.toggle() }
    }

    private func updateConfig(_ change: (inout WispConfig) -> Void) {
        do {
            try configStore.update(change)
        } catch {
            notice = Notice(error.localizedDescription)
        }
    }

    private func applyModelSettingsToSession() {
        objectWillChange.send()
        guard let sessionID else { return }
        Task {
            guard let agent = try? await host.running() else { return }
            await applyModelSettings(to: sessionID, on: agent)
        }
    }

    private func applyModelSettings(to session: String, on agent: GrokAgent) async {
        for (option, value) in [("model", config.model), ("reasoning_effort", config.reasoningEffort)] where !value.isEmpty {
            do {
                try await agent.setOption(option, to: value, in: session)
            } catch {
                Log.info("could not set \(option)=\(value): \(error.localizedDescription)")
                if option == "model" {
                    notice = Notice("Could not switch to \(catalog.name(of: value)): \(error.localizedDescription)")
                }
            }
        }
        host.refreshCatalog()
    }

    // MARK: History

    var historyMatches: [SessionHistory.Entry] { history.matching(historyFilter) }

    /// ⌘Y: the saved conversations, newest first, in place of the current one.
    /// `refreshing`: first drop sessions that are gone and adopt Grok Build's titles.
    func showHistory(refreshing: Bool = true) {
        if voice.isActive { voice.cancel() }
        historyFilter = ""
        selectedHistoryEntry = 0
        isShowingHistory = true
        focusRequest += 1
        if refreshing { refreshHistory() }
    }

    /// Back to the current conversation. A reopen still loading is abandoned.
    func closeHistory() {
        guard isShowingHistory else { return }
        isShowingHistory = false
        historyFilter = ""
        abandonReopen()
        focusRequest += 1
    }

    func toggleHistory() {
        if isShowingHistory { closeHistory() } else { showHistory() }
    }

    func moveHistorySelection(by offset: Int) {
        let count = historyMatches.count
        guard count > 0 else { return }
        selectedHistoryEntry = min(max(selectedHistoryEntry + offset, 0), count - 1)
    }

    /// ↩ reopens the highlighted conversation in the panel; ⌘↩ resumes it in Ghostty.
    func openHighlightedHistory(inGhostty: Bool) {
        guard let entry = historyMatches[safe: selectedHistoryEntry] else { return }
        if inGhostty {
            closeHistory()
            openRecent(entry)
        } else {
            reopen(entry)
        }
    }

    /// Drops conversations whose Grok Build session is gone and adopts the titles Grok Build generated.
    /// Waits for the login shell's environment, whose `GROK_HOME` can move the sessions.
    func refreshHistory() {
        guard let grokHome = host.resolvedGrokHome else {
            Task {
                _ = await host.environment()
                refreshHistory()
            }
            return
        }
        history.refresh(grokHome: grokHome)
        selectedHistoryEntry = min(selectedHistoryEntry, max(historyMatches.count - 1, 0))
    }

    /// Loads a saved conversation back into the panel with `session/load`. grok replays its turns before
    /// the load returns; they replace the current conversation only once it succeeds, so a failure, or
    /// going back with esc meanwhile, leaves the current one as it was.
    func reopen(_ entry: SessionHistory.Entry) {
        guard entry.id != sessionID else { return closeHistory() }
        guard reopening?.id != entry.id else { return }
        let attempt = UUID()
        reopenAttempt = attempt
        reopening = entry
        notice = nil
        let previous = reopenTask
        reopenTask = Task {
            // An abandoned load must finish first: its replay of the same session would mix into this one.
            await previous?.value
            guard reopenAttempt == attempt else { return }
            do {
                let agent = try await host.running()
                guard reopenAttempt == attempt else { return }
                replayed = Conversation(paths: paths)
                try await agent.load(entry.id, in: entry.directory)
                guard reopenAttempt == attempt else {
                    if sessionID != entry.id { await agent.close(entry.id) }
                    return
                }
                var loaded = replayed
                loaded.endReplay()
                replayed = Conversation(paths: paths)
                newConversation()  // stops and unloads the current session, and ends this reopen
                conversation = loaded
                sessionID = entry.id
                sessionDirectory = entry.directory
                await applyModelSettings(to: entry.id, on: agent)
            } catch {
                guard reopenAttempt == attempt else { return }
                abandonReopen()
                notice = Notice("Could not open “\(entry.title)”: \(error.localizedDescription)")
            }
        }
    }

    private func abandonReopen() {
        reopenAttempt = nil
        reopening = nil
    }

    // MARK: Ghostty

    static var ghosttyScript: URL {
        Bundle.main.url(forResource: "ghostty-grok", withExtension: nil)
            ?? WispPaths.standard.home.appending(path: "Applications/Wisp.app/Contents/Resources/ghostty-grok")
    }

    /// ⌘↩: typed text becomes a dev task the agent routes to the right project; otherwise this
    /// conversation continues as a full Grok Build session in Ghostty.
    func handOff() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && attachments.isEmpty {
            continueInGhostty()
        } else {
            let task = text.isEmpty ? "Work from what I attached." : text
            submit("Start a Grok Build dev session in Ghostty for this task:\n\n\(task)", quiet: true)
        }
    }

    /// Moves the conversation into `grok --resume` in Ghostty. A running answer is stopped first, and
    /// if Ghostty cannot open, the session is re-attached here so nothing is lost.
    func continueInGhostty() {
        guard !isHandingOff else { return }
        guard let session = sessionID else {
            open(GhosttyLauncher.Request(directory: host.workingDirectory, target: config.ghosttyTarget))
            return
        }
        isHandingOff = true
        notice = Notice("Opening in Ghostty…")
        let directory = sessionDirectory ?? host.workingDirectory
        Task {
            defer { isHandingOff = false }
            let agent = try? await host.running()
            if isWorking, let agent {
                await agent.cancel(session)
                for _ in 0..<50 where isWorking { try? await Task.sleep(for: .milliseconds(100)) }
            }
            // Unload here first so the TUI is the only process writing the session.
            await agent?.close(session)
            do {
                try await launcher().open(.init(directory: directory, resume: session, target: config.ghosttyTarget))
                if sessionID == session {
                    sessionID = nil
                    newConversation()
                }
                onRequestHide?()
            } catch {
                if let agent { try? await reattach(session, in: directory, on: agent) }
                show(error)
                focusRequest += 1
            }
        }
    }

    func openRecent(_ entry: SessionHistory.Entry) {
        if entry.id == sessionID {
            continueInGhostty()
        } else {
            open(GhosttyLauncher.Request(directory: entry.directory, resume: entry.id, target: config.ghosttyTarget))
        }
    }

    private func open(_ request: GhosttyLauncher.Request) {
        Task {
            do {
                try await launcher().open(request)
                onRequestHide?()
            } catch {
                show(error)
            }
        }
    }

    private func launcher() async -> GhosttyLauncher {
        var environment = await host.environment()
        environment["WISP_GROK"] = host.grokExecutable(in: environment).path
        return GhosttyLauncher(script: Self.ghosttyScript, environment: environment)
    }

    private func show(_ error: Error) {
        if let failure = error as? GhosttyLauncher.Failure, let url = failure.settingsURL {
            notice = Notice(failure.localizedDescription, actionTitle: "Open Settings", actionURL: url)
        } else {
            notice = Notice(error.localizedDescription)
        }
    }

    // MARK: Voice

    /// Starts dictation; `recording` (16 kHz mono 16-bit WAV bytes) stands in for the microphone.
    func startVoice(_ mode: VoiceController.Mode, recording: Data? = nil) {
        guard !voice.isActive, !isHandingOff else { return }
        closeHistory()
        notice = nil
        voiceBaseText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        voice.start(mode, recording: recording)
    }

    private func configureVoice() {
        voice.language = config.voiceLanguage
        voice.pauseSeconds = config.voicePauseSeconds
        voice.credentials = { [weak self] in
            guard let self else { throw CancellationError() }
            let environment = await host.environment()
            return try await GrokCredentials.bearer(
                environment: environment, grokHome: host.grokHome, grok: host.grokExecutable(in: environment))
        }
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            input = [voiceBaseText, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
        voice.onNotice = { [weak self] in self?.notice = Notice($0) }
        voice.onFinish = { [weak self] text, send in
            guard let self else { return }
            input = [voiceBaseText, text].filter { !$0.isEmpty }.joined(separator: " ")
            focusRequest += 1
            lastActivity = Date()
            if send { submit() }
        }
    }
}
