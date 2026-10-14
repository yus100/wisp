import Foundation

/// Runs a short-lived child process and collects its output.
///
/// Output goes to temporary files rather than pipes, so a chatty process can never fill a pipe buffer
/// and stall, and no reader thread is needed.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public let timedOut: Bool

        public var succeeded: Bool { status == 0 && !timedOut }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration? = nil
    ) async throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "wisp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outURL = scratch.appending(path: "stdout")
        let errURL = scratch.appending(path: "stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)

        let handle = ProcessHandle(process)
        let watchdog = timeout.map { limit in
            Task {
                try await Task.sleep(for: limit)
                handle.markTimedOut()
            }
        }
        defer { watchdog?.cancel() }

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }

        return Result(
            status: status,
            stdout: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: (try? Data(contentsOf: errURL)) ?? Data(),
            timedOut: handle.timedOut
        )
    }
}

/// Lets cancellation and timeout handlers, which run on other threads, stop the process.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didTimeOut = false

    init(_ process: Process) {
        self.process = process
    }

    var timedOut: Bool {
        lock.withLock { didTimeOut }
    }

    func markTimedOut() {
        lock.withLock { didTimeOut = true }
        terminate()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
