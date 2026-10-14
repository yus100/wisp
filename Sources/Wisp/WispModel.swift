import AppKit
import Foundation

/// State for the panel: one quick-answer conversation backed by a Grok Build session, plus voice input.
@MainActor
final class WispModel: ObservableObject {
    struct ToolActivity: Identifiable {
        let id: String
        var title: String
        var status: String
    }

    struct Turn: Identifiable {
        let id = UUID()
        var query: String
        var answer = ""
        var tools: [ToolActivity] = []
        var done = false
        var cancelled = false
        var error: String?
        /// Transient progress note, such as a retry after an API error.
        var status: String?
        /// Model that answered, as reported by the agent.
        var model: String?
        fileprivate var breakBeforeNextText = false
    }

    struct ModelOption: Identifiable {
        let id: String
        let name: String
        /// Reasoning efforts the model advertises; empty when the agent did not list them.
        let efforts: [String]
        let defaultEffort: String?
    }

    enum VoiceMode { case pushToTalk, handsFree }

    struct VoiceState {
        var active = false
        var connecting = false
        var finishing = false
        var level: Float = 0
        var mode = VoiceMode.handsFree
    }

    @Published var input = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isWorking = false
    @Published private(set) var voice = VoiceState()
    @Published var notice: String?
    @Published private(set) var focusRequest = 0
    @Published private(set) var models: [ModelOption] = []
    /// The default model from your Grok Build config.
    @Published private(set) var defaultModelId: String?

    /// Asks the panel to hide (for example after handing a session to Ghostty).
    var onRequestHide: (() -> Void)?
    var onHistoryChanged: (() -> Void)?
    /// Called after the app itself saves the config (model picker), so the delegate does not treat it as an edit.
    var onConfigSaved: ((AppConfig) -> Void)?

    private(set) var config: AppConfig
    private(set) var sessionId: String?
    let history = HistoryStore()

    private var env: [String: String]?
    private var agent: AgentClient?
    private var agentStarting: Task<AgentClient, Error>?
    private var lastActivity = Date()
    private var epoch = 0
    /// Effort levels reported by live sessions, for models whose initialize entry lists none.
    private var sessionEfforts: [String: [String]] = [:]

    private var voiceSession: VoiceSession?
    private var voiceBase = ""
    private var voiceCommitted = ""
    private var voiceInterim = ""
    private var voiceSendOnClose = false
    private var silenceTimer: Timer?
    private var noSpeechTimer: Timer?
    private var heardSpeech = false

    init(config: AppConfig) {
        self.config = config
    }

    var cwd: String { config.expandedWorkingDirectory }
    var hasConversation: Bool { !turns.isEmpty }

    func apply(config: AppConfig) {
        let restart = config.workingDirectory != self.config.workingDirectory || config.grokPath != self.config.grokPath
            || config.extraRules != self.config.extraRules
        let modelChanged = config.model != self.config.model || config.reasoningEffort != self.config.reasoningEffort
        self.config = config
        if restart {
            restartAgent()
        } else if modelChanged {
            applyModelToCurrentSession()
        }
    }

    // MARK: Panel lifecycle

    func panelWillShow() {
        if config.idleResetMinutes > 0, hasConversation, !isWorking, !voice.active,
           Date().timeIntervalSince(lastActivity) > config.idleResetMinutes * 60 {
            newConversation()
        }
        focusRequest += 1
        Task {
            let env = await ensureEnvironment()
            GrokAuth.prefetch(env: env, grokPath: grokPath)
            _ = try? await ensureAgent()
        }
    }

    // MARK: Agent

    private var rules: String {
        let script = Ghostty.scriptPath
        var text = """
        You are Wisp: the user opened you with a global hotkey from a Spotlight-style launcher on their Mac, \
        usually for a quick everyday question. Input may be a voice transcript, so read past speech-recognition errors.

        How to answer:
        - Lead with the answer. Default to one to four sentences or a short list; go longer only when asked or truly needed.
        - The panel renders basic Markdown. Skip headings, preambles, and narration of what you are about to do.
        - You run on the user's Mac with full, pre-approved access to their files, apps, and shell (working directory: \(cwd)). \
        Use tools whenever they make the answer correct: search and read files, inspect the system, run commands, search the web.
        - Do not use interactive question tools. If something is ambiguous, make a sensible assumption and say so in a few words.

        Dev sessions:
        When the user wants to build, fix, or work on code or a project ("start a dev session", "open a session in X", \
        "let's add Y to Z"), do not do the development here. Launch a full Grok Build session in a new Ghostty window:
          '\(script)' --cwd <project dir> [--prompt <task brief>]
        - Find the right project directory first; search for it if unsure, and create it if the user asks for a new project.
        - Make --prompt a self-contained brief that carries the relevant context from this conversation. Omit it when the \
        user only wants a session open. For multi-line briefs, use --prompt "$(cat <<'EOF' ... EOF)".
        - Then reply with one short line saying where the session opened.
        """
        if !config.extraRules.isEmpty { text += "\n\n" + config.extraRules }
        return text
    }

    private func ensureEnvironment() async -> [String: String] {
        if let env { return env }
        let resolved = await Task.detached { ShellEnvironment.resolve() }.value
        if env == nil {
            env = resolved
            appLog("environment resolved; grok at \(grokPath ?? "?")")
        }
        return env!
    }

    /// The configured grok binary, else the one on the login-shell PATH, else the default install location.
    var grokPath: String? {
        let configured = (config.grokPath as NSString).expandingTildeInPath
        if !configured.isEmpty { return configured }
        guard let env else { return nil }
        return ShellEnvironment.which("grok", env: env)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/bin/grok").path
    }

    func warmUp() {
        Task { _ = try? await ensureAgent() }
    }

    private func ensureAgent() async throws -> AgentClient {
        if let agent, agent.isRunning { return agent }
        if let agentStarting { return try await agentStarting.value }
        let task = Task { () throws -> AgentClient in
            let env = await ensureEnvironment()
            guard let grokPath, FileManager.default.isExecutableFile(atPath: grokPath) else {
                throw AgentError.rpc("Could not find the grok CLI. Install Grok Build or set grokPath in the config.")
            }
            let client = AgentClient(executable: grokPath, arguments: ["agent", "--always-approve", "stdio"],
                                     environment: env, cwd: cwd)
            client.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
            client.onExit = { [weak self, weak client] code in self?.agentExited(client, code: code) }
            try client.start()
            let initialized = try await client.request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "wisp", "version": "0.1.0"],
            ])
            loadModels(from: initialized)
            appLog("agent started")
            return client
        }
        agentStarting = task
        defer { agentStarting = nil }
        let client = try await task.value
        agent = client
        return client
    }

    private func agentExited(_ client: AgentClient?, code: Int32) {
        guard let client, client === agent else { return }
        appLog("agent exited with code \(code)")
        agent = nil
        if sessionId != nil {
            sessionId = nil
            if isWorking {
                updateLastTurn { $0.done = true; $0.error = AgentError.exited(code).localizedDescription }
                isWorking = false
            }
            if hasConversation { notice = "Grok restarted, so follow-ups start a new session." }
        }
    }

    func shutdown() {
        voiceSession?.cancel()
        agent?.onExit = nil
        agent?.stop()
        agent = nil
    }

    func restartAgent() {
        newConversation()
        agent?.onExit = nil
        agent?.stop()
        agent = nil
        warmUp()
    }

    private func ensureSession(_ agent: AgentClient) async throws -> String {
        if let sessionId { return sessionId }
        let result = try await agent.request("session/new", [
            "cwd": cwd,
            "mcpServers": [],
            "_meta": ["yoloMode": true, "rules": rules],
        ])
        guard let id = result["sessionId"] as? String else { throw AgentError.rpc("session/new returned no session ID") }
        learnEfforts(from: result)
        await applyModelSettings(sessionId: id, agent: agent)
        return id
    }

    // MARK: Model and effort

    var effectiveModelId: String? { config.model.isEmpty ? defaultModelId : config.model }

    var modelLabel: String {
        let id = effectiveModelId
        let name = models.first { $0.id == id }?.name ?? id ?? "Default model"
        let effort = config.reasoningEffort
        return effort.isEmpty ? name : "\(name) · \(Self.effortLabel(effort))"
    }

    static func effortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    func effortOptions(for modelId: String?) -> [String] {
        guard let modelId else { return [] }
        if let listed = models.first(where: { $0.id == modelId })?.efforts, !listed.isEmpty { return listed }
        return sessionEfforts[modelId] ?? ["low", "medium", "high", "xhigh"]
    }

    /// Picks a model for quick answers, keeps the effort when the model supports it, and saves both.
    func selectModel(_ id: String) {
        var updated = config
        updated.model = id
        let options = effortOptions(for: id)
        if !updated.reasoningEffort.isEmpty, !options.isEmpty, !options.contains(updated.reasoningEffort) {
            let fallback = models.first { $0.id == id }?.defaultEffort
            updated.reasoningEffort = options.contains("low") ? "low" : (fallback ?? options[0])
        }
        save(updated)
    }

    func selectEffort(_ effort: String) {
        var updated = config
        updated.reasoningEffort = effort
        save(updated)
    }

    private func save(_ updated: AppConfig) {
        config = updated
        updated.save()
        onConfigSaved?(updated)
        applyModelToCurrentSession()
        objectWillChange.send()
    }

    /// Applies the model and effort to the live session; new sessions pick them up in `ensureSession`.
    private func applyModelToCurrentSession() {
        objectWillChange.send()
        guard let sessionId, let agent else { return }
        Task { await applyModelSettings(sessionId: sessionId, agent: agent) }
    }

    private func applyModelSettings(sessionId id: String, agent: AgentClient) async {
        for (option, value) in [("model", config.model), ("reasoning_effort", config.reasoningEffort)] where !value.isEmpty {
            do {
                let result = try await agent.request("session/set_config_option",
                                                     ["sessionId": id, "configId": option, "value": value])
                learnEfforts(from: result)
            } catch {
                appLog("could not set \(option)=\(value): \(error.localizedDescription)")
                if option == "model" { notice = "Could not switch to \(value): \(error.localizedDescription)" }
            }
        }
    }

    private func loadModels(from initialized: JSON) {
        guard let state = (initialized["_meta"] as? JSON)?["modelState"] as? JSON else { return }
        defaultModelId = state["currentModelId"] as? String
        models = (state["availableModels"] as? [JSON] ?? []).compactMap { entry in
            guard let id = entry["modelId"] as? String else { return nil }
            let meta = entry["_meta"] as? JSON ?? [:]
            let efforts = (meta["reasoningEfforts"] as? [JSON] ?? []).compactMap { $0["value"] as? String }
            return ModelOption(id: id, name: (entry["name"] as? String) ?? id, efforts: efforts,
                               defaultEffort: meta["reasoningEffort"] as? String)
        }
    }

    /// `session/new` and `set_config_option` return the session's options, including the effort levels its model accepts.
    private func learnEfforts(from result: JSON) {
        guard let options = result["configOptions"] as? [JSON],
              let model = options.first(where: { $0["id"] as? String == "model" })?["currentValue"] as? String,
              let effort = options.first(where: { $0["id"] as? String == "reasoning_effort" }) else { return }
        let values = (effort["options"] as? [JSON] ?? []).compactMap { $0["value"] as? String }
        if !values.isEmpty { sessionEfforts[model] = values }
    }

    // MARK: Conversation

    func submit(_ override: String? = nil) {
        let text = (override ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if voice.active { cancelVoice() }
        guard !isWorking else {
            notice = "Still answering. Press ⌘. to stop it first."
            return
        }
        input = ""
        notice = nil
        turns.append(Turn(query: text))
        isWorking = true
        lastActivity = Date()
        let myEpoch = epoch
        Task {
            do {
                let agent = try await ensureAgent()
                let id = try await ensureSession(agent)
                guard myEpoch == epoch else { return }
                sessionId = id
                history.touch(sessionId: id, title: turns.first?.query ?? text, cwd: cwd)
                onHistoryChanged?()
                let result = try await agent.request("session/prompt", [
                    "sessionId": id,
                    "prompt": [["type": "text", "text": text]],
                ])
                guard myEpoch == epoch else { return }
                let stop = result["stopReason"] as? String
                let answeredBy = (result["_meta"] as? JSON)?["modelId"] as? String
                updateLastTurn {
                    $0.done = true
                    $0.cancelled = stop == "cancelled"
                    $0.model = answeredBy
                }
            } catch {
                guard myEpoch == epoch else { return }
                updateLastTurn {
                    $0.done = true
                    $0.error = error.localizedDescription
                }
            }
            isWorking = false
            lastActivity = Date()
        }
    }

    func cancel() {
        guard isWorking, let sessionId else { return }
        agent?.notify("session/cancel", ["sessionId": sessionId])
    }

    func newConversation() {
        cancelVoice()
        if isWorking { cancel() }
        if let sessionId, let agent {
            Task { _ = try? await agent.request("session/close", ["sessionId": sessionId]) }
        }
        epoch += 1
        sessionId = nil
        turns = []
        input = ""
        notice = nil
        isWorking = false
        lastActivity = Date()
        focusRequest += 1
    }

    func copyLastAnswer() {
        guard let answer = turns.last?.answer, !answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        notice = "Copied answer"
    }

    /// ⌘↩: typed text becomes a dev task that the agent routes to the right project; otherwise the
    /// current conversation moves into a full Grok Build session in Ghostty.
    func openInGhostty() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            submit("Start a Grok Build dev session in Ghostty for this task:\n\n\(text)")
            return
        }
        guard let sessionId else {
            launchGhostty(resume: nil, cwd: cwd)
            return
        }
        if isWorking {
            notice = "Wait for the answer to finish (or press ⌘. to stop it) before moving to Ghostty."
            return
        }
        // Close the session here first so the TUI is the only process writing to it.
        let agent = agent
        Task {
            _ = try? await agent?.request("session/close", ["sessionId": sessionId])
            launchGhostty(resume: sessionId, cwd: cwd, resetOnSuccess: true)
        }
    }

    func openHistory(_ entry: HistoryStore.Entry) {
        if entry.id == sessionId {
            openInGhostty()
        } else {
            launchGhostty(resume: entry.id, cwd: entry.cwd)
        }
    }

    private func launchGhostty(resume: String?, cwd: String, resetOnSuccess: Bool = false) {
        Task {
            let env = await ensureEnvironment()
            Ghostty.open(cwd: cwd, resume: resume, target: config.ghosttyTarget, env: env) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.notice = error
                    return
                }
                if resetOnSuccess {
                    self.sessionId = nil
                    self.newConversation()
                }
                self.onRequestHide?()
            }
        }
    }

    // MARK: Agent updates

    private func handleNotification(_ method: String, _ params: JSON) {
        guard isWorking, let id = params["sessionId"] as? String, id == sessionId,
              let update = params["update"] as? JSON,
              let kind = update["sessionUpdate"] as? String else { return }
        switch (method, kind) {
        case ("session/update", "agent_message_chunk"):
            guard let text = (update["content"] as? JSON)?["text"] as? String else { return }
            updateLastTurn { turn in
                if turn.breakBeforeNextText, !turn.answer.isEmpty, !turn.answer.hasSuffix("\n\n") {
                    turn.answer += "\n\n"
                }
                turn.breakBeforeNextText = false
                turn.status = nil
                turn.answer += text
            }
        case ("session/update", "tool_call"):
            let toolId = (update["toolCallId"] as? String) ?? UUID().uuidString
            let title = Self.describeTool(update)
            let status = (update["status"] as? String) ?? "pending"
            updateLastTurn { turn in
                if let index = turn.tools.firstIndex(where: { $0.id == toolId }) {
                    turn.tools[index].title = title
                } else {
                    turn.tools.append(ToolActivity(id: toolId, title: title, status: status))
                }
                turn.breakBeforeNextText = true
            }
        case ("session/update", "tool_call_update"):
            guard let toolId = update["toolCallId"] as? String else { return }
            updateLastTurn { turn in
                guard let index = turn.tools.firstIndex(where: { $0.id == toolId }) else { return }
                if let status = update["status"] as? String { turn.tools[index].status = status }
                if let title = update["title"] as? String, title.contains(" ") {
                    turn.tools[index].title = Self.tidy(title)
                }
            }
        case ("_x.ai/session_notification", "retry_state"):
            let state = update["type"] as? String
            updateLastTurn { turn in
                switch state {
                case "retrying":
                    let attempt = (update["attempt"] as? Int) ?? 1
                    let max = (update["max_retries"] as? Int) ?? (update["maxRetries"] as? Int)
                    turn.status = "Grok is busy, retrying" + (max.map { " (\(attempt)/\($0))" } ?? "") + "…"
                case "exhausted":
                    turn.status = nil
                    turn.error = (update["reason"] as? String) ?? "Grok is unavailable. Try again in a moment."
                case "failed":
                    turn.status = nil
                    let message = (update["message"] as? String) ?? "Request failed."
                    let auth = (update["error_type"] as? String ?? update["errorType"] as? String) == "auth"
                    turn.error = auth ? "\(message) Run `grok login` in a terminal." : message
                default:
                    break
                }
            }
        default:
            break
        }
    }

    private static func describeTool(_ update: JSON) -> String {
        let title = update["title"] as? String
        if let title, title.contains(" ") { return tidy(title) }
        let input = update["rawInput"] as? JSON
        if let command = input?["command"] as? String { return tidy("Run `\(command)`") }
        if let query = input?["query"] as? String { return tidy("Search “\(query)”") }
        for key in ["target_file", "file_path", "path", "target_directory"] {
            if let path = input?[key] as? String { return tidy("\(title ?? "Read") \(path)") }
        }
        return (title ?? "Tool").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func tidy(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let flat = text.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
    }

    private func updateLastTurn(_ change: (inout Turn) -> Void) {
        guard !turns.isEmpty else { return }
        change(&turns[turns.count - 1])
    }

    // MARK: Voice

    var isListening: Bool { voice.active }

    func startVoice(mode: VoiceMode, file: URL? = nil) {
        guard !voice.active else { return }
        notice = nil
        voice = VoiceState(active: true, connecting: true, finishing: false, level: 0, mode: mode)
        voiceBase = input.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceCommitted = ""
        voiceInterim = ""
        voiceSendOnClose = false
        heardSpeech = false
        let session = VoiceSession()
        voiceSession = session
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, session === self.voiceSession else { return }
            self.handleVoice(event)
        }
        Task {
            if let file {
                do { try session.startFile(file) } catch { failVoice(error.localizedDescription); return }
                voiceSendOnClose = true
            } else {
                if VoiceSession.microphoneAccessUndecided {
                    notice = "Allow microphone access in the macOS prompt to use voice."
                }
                guard await VoiceSession.requestMicrophoneAccess() else {
                    failVoice("Microphone access is off. Turn on Wisp in System Settings › Privacy & Security › Microphone.")
                    return
                }
                // The key may have been released while the permission prompt was up.
                guard session === voiceSession, !voice.finishing else { return }
                do { try session.startMicrophone() } catch { failVoice(error.localizedDescription); return }
                if notice?.hasPrefix("Allow microphone") == true { notice = nil }
            }
            startNoSpeechTimer()
            do {
                let env = await ensureEnvironment()
                let bearer = try await GrokAuth.bearer(env: env, grokPath: grokPath)
                guard session === voiceSession else { return }
                session.connect(bearer: bearer, language: config.voiceLanguage)
            } catch {
                failVoice(error.localizedDescription)
            }
        }
    }

    /// Stops listening; with `send`, the transcript is submitted once the server finalizes it.
    func finishVoice(send: Bool) {
        guard voice.active, let voiceSession else { return }
        silenceTimer?.invalidate()
        noSpeechTimer?.invalidate()
        voiceSendOnClose = send
        voice.finishing = true
        voiceSession.finish()
    }

    /// Stops listening and keeps whatever was transcribed in the input, unsent.
    func cancelVoice() {
        guard voice.active else { return }
        voiceSession?.cancel()
        endVoice()
    }

    private func handleVoice(_ event: VoiceSession.Event) {
        switch event {
        case .ready:
            voice.connecting = false
        case .level(let level):
            voice.level = level
        case .interim(let text):
            heardSpeech = true
            voiceInterim = text
            silenceTimer?.invalidate()
            refreshVoiceInput()
        case .utterance(let text):
            heardSpeech = true
            voiceCommitted = [voiceCommitted, text].filter { !$0.isEmpty }.joined(separator: " ")
            voiceInterim = ""
            refreshVoiceInput()
            if voice.mode == .handsFree, config.voiceSilenceSeconds > 0, !voice.finishing {
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: config.voiceSilenceSeconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.finishVoice(send: true) }
                }
            }
        case .error(let message):
            notice = message
        case .closed:
            if !voiceInterim.isEmpty {
                voiceCommitted = [voiceCommitted, voiceInterim].filter { !$0.isEmpty }.joined(separator: " ")
                voiceInterim = ""
                refreshVoiceInput()
            }
            let send = voiceSendOnClose && !voiceCommitted.isEmpty
            endVoice()
            if send { submit() }
        }
    }

    private func refreshVoiceInput() {
        input = [voiceBase, voiceCommitted, voiceInterim].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func startNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.voice.active, !self.heardSpeech else { return }
                self.finishVoice(send: false)
                self.notice = "No speech detected. Check the input device in System Settings › Sound."
            }
        }
    }

    private func failVoice(_ message: String) {
        voiceSession?.cancel()
        endVoice()
        notice = message
    }

    private func endVoice() {
        silenceTimer?.invalidate()
        noSpeechTimer?.invalidate()
        voiceSession = nil
        voice = VoiceState()
        lastActivity = Date()
        focusRequest += 1
    }
}
