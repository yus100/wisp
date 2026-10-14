import Foundation
import WispCore

/// Keeps one warm `grok agent` running with the user's login-shell environment, restarting it on demand.
@MainActor
final class AgentHost {
    /// Streamed updates for every session on the current agent.
    var onSessionUpdate: ((SessionNotification) -> Void)?
    /// The agent died on its own; sessions it had loaded must be re-attached.
    var onUnexpectedExit: ((Int32) -> Void)?
    /// The model list changed (agent start, or efforts learned from a session).
    var onCatalogChange: ((ModelCatalog) -> Void)?

    private(set) var catalog = ModelCatalog()
    private var config: WispConfig
    private let paths: WispPaths
    private var environmentTask: Task<[String: String], Never>?
    private var resolvedEnvironment: [String: String]?
    private var agent: GrokAgent?
    private var starting: Task<GrokAgent, Error>?

    init(config: WispConfig, paths: WispPaths) {
        self.config = config
        self.paths = paths
    }

    var workingDirectory: String { paths.expand(config.workingDirectory) }

    /// Picks up settings that affect the agent process; restarts it when they changed.
    func apply(_ config: WispConfig) {
        let restart = config.workingDirectory != self.config.workingDirectory
            || config.grokPath != self.config.grokPath
            || config.ghosttyTarget != self.config.ghosttyTarget
        self.config = config
        if restart { self.restart() }
    }

    // MARK: Environment

    /// The login shell's environment, resolved once and shared by every caller.
    func environment() async -> [String: String] {
        if let resolvedEnvironment { return resolvedEnvironment }
        let task = environmentTask ?? Task.detached { await ShellEnvironment.resolve() }
        environmentTask = task
        let environment = await task.value
        resolvedEnvironment = environment
        return environment
    }

    /// The configured grok, else the one on the login shell's PATH, else the default install location.
    func grokExecutable(in environment: [String: String]) -> URL {
        let configured = paths.expand(config.grokPath)
        if !configured.isEmpty { return URL(filePath: configured) }
        if let found = ShellEnvironment.which("grok", in: environment) { return URL(filePath: found) }
        return paths.home.appending(path: ".grok/bin/grok")
    }

    /// Grok Build's home, honoring `GROK_HOME` from the login shell once it is known.
    var grokHome: URL {
        paths.grokHome(environment: resolvedEnvironment ?? [:])
    }

    /// What the agent (and the `ghostty-grok` runs it makes) sees: the login environment plus Wisp's settings.
    private func agentEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["WISP_GHOSTTY_TARGET"] = config.ghosttyTarget.rawValue
        if !config.grokPath.isEmpty { environment["WISP_GROK"] = paths.expand(config.grokPath) }
        return environment
    }

    // MARK: Agent lifecycle

    /// The running agent, starting it if needed. Concurrent callers share one start.
    func running() async throws -> GrokAgent {
        if let agent, agent.isRunning { return agent }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        let started = try await task.value
        agent = started
        return started
    }

    private func launch() async throws -> GrokAgent {
        let base = await environment()
        let executable = grokExecutable(in: base)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HostError.grokNotFound(executable.path)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let agent = GrokAgent(launch: .init(
            executable: executable,
            environment: agentEnvironment(base),
            workingDirectory: URL(filePath: workingDirectory),
            clientVersion: version))
        agent.onSessionUpdate = { [weak self] in self?.onSessionUpdate?($0) }
        agent.onUnexpectedExit = { [weak self, weak agent] status in
            guard let self, let agent, agent === self.agent else { return }
            self.agent = nil
            self.onUnexpectedExit?(status)
        }
        try await agent.start()
        publishCatalog(agent.catalog)
        return agent
    }

    func restart() {
        starting?.cancel()
        agent?.stop()
        agent = nil
        Task { _ = try? await running() }
    }

    func shutdown() {
        starting?.cancel()
        agent?.stop()
        agent = nil
    }

    /// Call after anything that can teach the catalog new effort levels.
    func refreshCatalog() {
        if let agent { publishCatalog(agent.catalog) }
    }

    private func publishCatalog(_ catalog: ModelCatalog) {
        guard catalog != self.catalog else { return }
        self.catalog = catalog
        onCatalogChange?(catalog)
    }

    enum HostError: LocalizedError {
        case grokNotFound(String)

        var errorDescription: String? {
            switch self {
            case .grokNotFound(let path):
                "Could not find the grok CLI at \(path). Install Grok Build (https://x.ai/cli) or set grokPath in the config."
            }
        }
    }
}
