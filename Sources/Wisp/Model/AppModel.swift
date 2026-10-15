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
/// session, voice input, model choice, and hand-off to Ghostty.
@MainActor
final class AppModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var conversation: Conversation
    @Published var notice: Notice?
    @Published private(set) var catalog = ModelCatalog()
    @Published private(set) var isHandingOff = false
    /// Bumped whenever the input field should take focus.
    @Published private(set) var focusRequest = 0

    let voice = VoiceController()
    private(set) var history: SessionHistory
    private(set) var sessionID: String?

    /// Hide the panel (after a hand-off opens Ghostty).
    var onRequestHide: (() -> Void)?

    private let configStore: ConfigStore
    private let host: AgentHost
    private let paths: WispPaths
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

    init(configStore: ConfigStore, paths: WispPaths = .standard) {
        self.configStore = configStore
        self.paths = paths
        host = AgentHost(config: configStore.config, paths: paths)
        conversation = Conversation(paths: paths)
        history = SessionHistory(file: paths.historyFile)
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
            // The restarted agent has none of the old sessions loaded; the old one stays in Open Recent.
            newConversation()
        }
        voice.language = new.voiceLanguage
        voice.pauseSeconds = new.voicePauseSeconds
        if old.model != new.model || old.reasoningEffort != new.reasoningEffort {
            applyModelSettingsToSession()
        }
    }

    func panelWillShow() {
        if config.idleResetMinutes > 0, !conversation.isEmpty, !isWorking, !voice.isActive, !isHandingOff,
            Date().timeIntervalSince(lastActivity) > config.idleResetMinutes * 60
        {
            newConversation()
        }
        focusRequest += 1
        Task {
            let environment = await host.environment()
            GrokCredentials.prefetch(
                environment: environment, grokHome: host.grokHome, grok: host.grokExecutable(in: environment))
            _ = try? await host.running()
        }
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

    func submit(_ text: String? = nil) {
        let query = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isHandingOff else { return }
        if voice.isActive { voice.cancel() }
        guard !isWorking else {
            notice = Notice("Still answering. Press ⌘. to stop it first.")
            return
        }
        input = ""
        notice = nil
        stopRequested = false
        conversation.begin(query)
        let turnID = conversation.turns.last?.id
        let conversationID = conversationID
        lastActivity = Date()
        promptTask = Task {
            defer { lastActivity = Date() }
            do {
                let (agent, session) = try await activeSession(for: conversationID)
                history.record(session, title: conversation.turns.first?.query ?? query, directory: host.workingDirectory)
                if stopRequested {
                    stopRequested = false
                    conversation.finish(stopReason: "cancelled", model: nil)
                    return
                }
                let result = try await agent.prompt(query, in: session)
                guard conversation.turns.last?.id == turnID else { return }
                conversation.finish(stopReason: result.stopReason, model: result.modelID)
                host.refreshCatalog()
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
        conversation = Conversation(paths: paths)
        input = ""
        notice = nil
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
        let rules = QuickAnswerRules.text(
            workingDirectory: host.workingDirectory, ghosttyScript: Self.ghosttyScript.path, extra: config.extraRules)
        let session = try await agent.newSession(in: host.workingDirectory, rules: rules).sessionId
        guard conversationID == conversation else {
            await agent.close(session)
            throw CancellationError()
        }
        sessionID = session
        await applyModelSettings(to: session, on: agent)
        return (agent, session)
    }

    /// Loads a saved session into the agent. grok replays its history as updates, which must not
    /// land in a running turn, so updates are ignored until the load returns (they all arrive before it).
    private func reattach(_ session: String, on agent: GrokAgent) async throws {
        ignoringUpdates = true
        defer { ignoringUpdates = false }
        try await agent.load(session, in: host.workingDirectory)
        await applyModelSettings(to: session, on: agent)
    }

    /// The agent crashed: fail the running turn, then re-attach the session on a fresh agent so
    /// follow-ups keep their context.
    private func agentDied(status: Int32) {
        if isWorking { conversation.fail("The agent stopped unexpectedly (status \(status)). Ask again to continue.") }
        guard let session = sessionID else { return }
        reattaching = Task {
            defer { reattaching = nil }
            do {
                try await reattach(session, on: try await host.running())
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

    // MARK: Ghostty

    static var ghosttyScript: URL {
        Bundle.main.url(forResource: "ghostty-grok", withExtension: nil)
            ?? WispPaths.standard.home.appending(path: "Applications/Wisp.app/Contents/Resources/ghostty-grok")
    }

    /// ⌘↩: typed text becomes a dev task the agent routes to the right project; otherwise this
    /// conversation continues as a full Grok Build session in Ghostty.
    func handOff() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            continueInGhostty()
        } else {
            submit("Start a Grok Build dev session in Ghostty for this task:\n\n\(text)")
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
                try await launcher().open(.init(directory: host.workingDirectory, resume: session, target: config.ghosttyTarget))
                if sessionID == session {
                    sessionID = nil
                    newConversation()
                }
                onRequestHide?()
            } catch {
                if let agent { try? await reattach(session, on: agent) }
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

    /// Recent sessions, retitled with the titles Grok Build generated for them.
    func refreshHistoryTitles() {
        history.adoptGrokTitles(grokHome: host.grokHome)
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
