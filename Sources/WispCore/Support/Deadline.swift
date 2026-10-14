import Foundation

public struct TimedOut: LocalizedError, Equatable, Sendable {
    public let what: String

    public var errorDescription: String? { "Timed out waiting for \(what)." }
}

/// Runs `operation`, failing with `TimedOut` if it takes longer than `limit`. Cancels the operation on timeout.
func withDeadline<T: Sendable>(
    _ limit: Duration, _ what: String, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimedOut(what: what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
