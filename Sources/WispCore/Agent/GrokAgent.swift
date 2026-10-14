import Foundation

/// A long-lived `grok agent --always-approve stdio` process and the ACP session API on top of it.
///
/// One agent serves every conversation; each conversation is an ordinary Grok Build session, saved
/// where `grok --resume` finds it. The process starts in about a tenth of a second and stays warm,
/// so the first token of an answer is only a model round trip away.
@MainActor
public final class GrokAgent {
    public struct Launch: Sendable {
        public var executable: URL
        public var environment: [String: String]
        public var workingDirectory: URL
        public var clientVersion: String

        public init(executable: URL, environment: [String: String], workingDirectory: URL, clientVersion: String) {
            self.executable = executable
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.clientVersion = clientVersion
        }
    }

    public private(set) var catalog = ModelCatalog()
    public private(set) var isRunning = false

    /// Streamed updates for any session on this agent.
    public var onSessionUpdate: ((SessionNotification) -> Void)?
    /// The process exited without `stop()` being called.
    public var onUnexpectedExit: ((Int32) -> Void)?

    private let launch: Launch
    private var process: Process?
    private var connection: ACPConnection?
    private var stopping = false

    public init(launch: Launch) {
        self.launch = launch
    }

    /// Spawns the process and runs the ACP handshake, which also delivers the model list.
    public func start() async throws {
        precondition(process == nil, "GrokAgent.start() called twice")
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = ["agent", "--always-approve", "stdio"]
        process.environment = launch.environment
        process.currentDirectoryURL = launch.workingDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Log.appendingHandle(for: "agent.log")

        let writer = input.fileHandleForWriting
        let connection = ACPConnection { data in try writer.write(contentsOf: data) }
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Data.self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                chunkSink.finish()
            } else {
                chunkSink.yield(data)
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processDidExit(status) }
        }

        try process.run()
        self.process = process
        self.connection = connection
        isRunning = true

        // A single reader handles every message before reading the next, so updates stay in order
        // and all of a turn's chunks are applied before its `session/prompt` reply returns.
        Task.detached { [weak self] in
            var framer = LineFramer()
            for await chunk in chunks {
                for line in framer.append(chunk) {
                    if let message = await connection.receive(line) {
                        await self?.handle(message, on: connection)
                    }
                }
            }
            await connection.close()
        }

        do {
            let clientVersion = launch.clientVersion
            let result = try await withDeadline(.seconds(30), "grok to start") {
                try await connection.request(
                    "initialize",
                    params: InitializeParams(clientInfo: .init(name: "wisp", version: clientVersion)),
                    as: InitializeResult.self)
            }
            catalog = ModelCatalog(result)
        } catch {
            stop()
            throw error
        }
        Log.info("agent started (\(catalog.models.count) models, default \(catalog.defaultModelID ?? "unknown"))")
    }

    public func stop() {
        stopping = true
        process?.terminate()
    }

    // MARK: Sessions

    /// Creates a session with always-approve and extra system-prompt rules.
    public func newSession(in directory: String, rules: String) async throws -> NewSessionResult {
        let result = try await requireConnection().request(
            "session/new",
            params: NewSessionParams(cwd: directory, meta: .init(yoloMode: true, rules: rules)),
            as: NewSessionResult.self)
        if let options = result.configOptions { catalog.learn(from: options) }
        return result
    }

    /// Sends a prompt and waits for the turn to end; text and tool activity arrive through `onSessionUpdate`.
    public func prompt(_ text: String, in sessionID: String) async throws -> PromptResult {
        try await requireConnection().request(
            "session/prompt",
            params: PromptParams(sessionId: sessionID, prompt: [.init(text: text)]),
            as: PromptResult.self)
    }

    /// Asks the agent to stop the running turn; `prompt` then returns with stop reason `cancelled`.
    public func cancel(_ sessionID: String) async {
        await connection?.notify("session/cancel", params: SessionParams(sessionId: sessionID))
    }

    /// Re-attaches a saved session, for example after the agent restarted. grok replays the history as
    /// updates; they arrive while no turn is running, so `Conversation` ignores them.
    public func load(_ sessionID: String, in directory: String) async throws {
        _ = try await requireConnection().request(
            "session/load", params: LoadSessionParams(sessionId: sessionID, cwd: directory), as: EmptyResult.self)
    }

    /// Unloads a session from this agent. It stays on disk, so `grok --resume` can pick it up.
    public func close(_ sessionID: String) async {
        do {
            _ = try await requireConnection().request("session/close", params: SessionParams(sessionId: sessionID), as: EmptyResult.self)
        } catch {
            Log.info("session/close \(sessionID): \(error.localizedDescription)")
        }
    }

    /// Sets `model` or `reasoning_effort` on a session.
    public func setOption(_ configID: String, to value: String, in sessionID: String) async throws {
        let result = try await requireConnection().request(
            "session/set_config_option",
            params: SetConfigOptionParams(sessionId: sessionID, configId: configID, value: value),
            as: SetConfigOptionResult.self)
        if let options = result.configOptions { catalog.learn(from: options) }
    }

    // MARK: Private

    private func requireConnection() throws -> ACPConnection {
        guard isRunning, let connection else { throw ACPError.disconnected }
        return connection
    }

    private func handle(_ message: ACPConnection.Incoming, on connection: ACPConnection) async {
        let decoder = JSONDecoder()
        switch message {
        case .notification(let method, let data) where method == "session/update" || method == "_x.ai/session_notification":
            guard let notification = try? decoder.decode(IncomingParams<SessionNotification>.self, from: data).params else { return }
            onSessionUpdate?(notification)
        case .notification:
            break
        case .request(let id, "session/request_permission", let data):
            // Sessions run with always-approve, so this should not happen. Approving once keeps the turn from
            // hanging without saving an "always allow" rule into the user's own grok settings.
            let options = (try? decoder.decode(IncomingParams<PermissionRequest>.self, from: data).params.options) ?? []
            let choice = options.first { $0.kind == "allow_once" } ?? options.first { $0.kind?.hasPrefix("allow") == true }
            let outcome = choice.map { PermissionResponse.Outcome(outcome: "selected", optionId: $0.optionId) }
                ?? PermissionResponse.Outcome(outcome: "cancelled", optionId: nil)
            await connection.respond(to: id, result: PermissionResponse(outcome: outcome))
        case .request(let id, let method, _):
            Log.info("acp: declined unsupported agent request \(method)")
            await connection.respond(to: id, errorCode: -32601, message: "Wisp does not support \(method)")
        }
    }

    private func processDidExit(_ status: Int32) {
        guard isRunning else { return }
        isRunning = false
        let expected = stopping
        Task { await connection?.close() }
        Log.info("agent exited with status \(status)\(expected ? "" : " (unexpected)")")
        if !expected { onUnexpectedExit?(status) }
    }
}
