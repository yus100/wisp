import Foundation

/// Opens Grok Build sessions in Ghostty by running the bundled `ghostty-grok` script, which the agent
/// also runs when you ask it to start a dev session.
public struct GhosttyLauncher: Sendable {
    public struct Request: Equatable, Sendable {
        public var directory: String
        /// Continue this grok session instead of starting a new one.
        public var resume: String?
        /// First message for a new session.
        public var prompt: String?
        public var target: WispConfig.GhosttyTarget

        public init(directory: String, resume: String? = nil, prompt: String? = nil, target: WispConfig.GhosttyTarget) {
            self.directory = directory
            self.resume = resume
            self.prompt = prompt
            self.target = target
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case notInstalled(String)
        case notPermitted
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let message), .failed(let message): message
            case .notPermitted: "Wisp is not allowed to control Ghostty. Turn it on in System Settings › Privacy & Security › Automation."
            }
        }

        /// Opens the settings pane that fixes this failure, when there is one.
        public var settingsURL: URL? {
            self == .notPermitted ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") : nil
        }
    }

    public let script: URL
    public let environment: [String: String]

    public init(script: URL, environment: [String: String]) {
        self.script = script
        self.environment = environment
    }

    public func open(_ request: Request) async throws {
        let result = try await ProcessRunner.run(script, arguments: arguments(for: request), environment: environment, timeout: .seconds(30))
        guard !result.succeeded else { return }
        let message = result.stderrText.replacingOccurrences(of: "ghostty-grok: ", with: "")
        switch result.status {
        case 3: throw Failure.notInstalled(message)
        case 4: throw Failure.notPermitted
        default: throw Failure.failed(result.timedOut ? "Ghostty did not respond." : message.isEmpty ? "Could not open Ghostty." : message)
        }
    }

    /// What `open` would do, as reported by the script's `--dry-run`.
    func describe(_ request: Request) async throws -> String {
        let result = try await ProcessRunner.run(script, arguments: arguments(for: request) + ["--dry-run"], environment: environment)
        return String(decoding: result.stdout, as: UTF8.self) + result.stderrText
    }

    func arguments(for request: Request) -> [String] {
        var arguments = ["--cwd", request.directory, request.target == .tab ? "--tab" : "--window"]
        if let resume = request.resume { arguments += ["--resume", resume] }
        if let prompt = request.prompt, !prompt.isEmpty { arguments += ["--prompt", prompt] }
        return arguments
    }
}
