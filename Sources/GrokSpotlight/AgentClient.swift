import Foundation

typealias JSON = [String: Any]

enum AgentError: LocalizedError {
    case notRunning
    case exited(Int32)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Grok agent is not running."
        case .exited(let code): return "Grok agent exited (code \(code)). See ~/Library/Logs/GrokSpotlight/agent.log."
        case .rpc(let message): return message
        }
    }
}

/// Minimal ACP (Agent Client Protocol) client for `grok agent stdio`: newline-delimited JSON-RPC 2.0 over pipes.
final class AgentClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private let writeQueue = DispatchQueue(label: "grok-spotlight.agent.write")

    /// Agent notifications (`session/update` and the `_x.ai/*` extensions), delivered on the main queue.
    var onNotification: ((String, JSON) -> Void)?
    /// Called on the main queue when the process exits.
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false

    init(executable: String, arguments: [String], environment: [String: String], cwd: String) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = AgentClient.stderrLog()
    }

    private static func stderrLog() -> FileHandle {
        let url = AppPaths.logs.appendingPathComponent("agent.log")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
        handle.seekToEndOfFile()
        return handle
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.isRunning = false
            self.failAll(AgentError.exited(proc.terminationStatus))
            let code = proc.terminationStatus
            DispatchQueue.main.async { self.onExit?(code) }
        }
        try process.run()
        isRunning = true
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: JSON-RPC

    func request(_ method: String, _ params: JSON) async throws -> JSON {
        guard isRunning else { throw AgentError.notRunning }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextId
            nextId += 1
            pending[id] = continuation
            lock.unlock()
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    func notify(_ method: String, _ params: JSON) {
        guard isRunning else { return }
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ message: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async {
            do {
                try handle.write(contentsOf: data + Data([0x0A]))
            } catch {
                appLog("agent write failed: \(error)")
            }
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? JSON else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            answerAgentRequest(id: id, method: method, params: message["params"] as? JSON ?? [:])
            return
        }
        if let method {
            let params = message["params"] as? JSON ?? [:]
            DispatchQueue.main.async { self.onNotification?(method, params) }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if let error = message["error"] as? JSON {
            let text = (error["message"] as? String) ?? "Agent error"
            let detail = (error["data"] as? String).map { ": \($0)" } ?? ""
            continuation.resume(throwing: AgentError.rpc(text + detail))
        } else {
            continuation.resume(returning: message["result"] as? JSON ?? [:])
        }
    }

    /// Requests from the agent to the client. Sessions run with always-approve, so permission prompts
    /// should not happen; if one does, approve it rather than leaving the turn hanging.
    private func answerAgentRequest(id: Any, method: String, params: JSON) {
        if method == "session/request_permission" {
            let options = params["options"] as? [JSON] ?? []
            let preferred = options.first { ($0["kind"] as? String) == "allow_always" }
                ?? options.first { ($0["kind"] as? String) == "allow_once" }
                ?? options.first
            if let optionId = preferred?["optionId"] as? String {
                send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": optionId]]])
            } else {
                send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
            }
            return
        }
        appLog("agent request not supported: \(method)")
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Grok Spotlight does not support \(method)"]])
    }
}
