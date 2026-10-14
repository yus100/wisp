import Foundation

/// JSON-RPC 2.0 over newline-delimited JSON, as used by the Agent Client Protocol.
///
/// Transport-agnostic: the owner supplies a `send` function for outgoing bytes and feeds each received
/// line to `receive(_:)`. Replies resume the matching `request`; notifications and requests from the
/// agent are returned for the owner to handle. Handling each one before receiving the next line keeps
/// every update that preceded a reply ahead of that reply, so a turn never ends before its last chunk.
public actor ACPConnection {
    public enum Incoming: Sendable {
        case notification(method: String, message: Data)
        case request(id: RequestID, method: String, message: Data)
    }

    private let send: @Sendable (Data) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var closedError: ACPError?

    public init(send: @escaping @Sendable (Data) throws -> Void) {
        self.send = send
    }

    // MARK: Outgoing

    public func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, params: Params, as resultType: Result.Type = Result.self
    ) async throws -> Result {
        if let closedError { throw closedError }
        let id = nextID
        nextID += 1
        let message = try encoder.encode(OutgoingRequest(id: id, method: method, params: params))
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(message + Data([0x0A]))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
        if let error = try decoder.decode(IncomingError.self, from: reply).error {
            let detail = error.data.map { ": \($0)" } ?? ""
            throw ACPError.rpc(code: error.code, message: error.message + detail)
        }
        if let result = try decoder.decode(IncomingResult<Result>.self, from: reply).result {
            return result
        }
        if let empty = EmptyResult() as? Result { return empty }
        throw ACPError.missingResult(method: method)
    }

    public func notify<Params: Encodable & Sendable>(_ method: String, params: Params) {
        guard closedError == nil, let message = try? encoder.encode(OutgoingNotification(method: method, params: params)) else { return }
        try? send(message + Data([0x0A]))
    }

    public func respond<Result: Encodable & Sendable>(to id: RequestID, result: Result) {
        guard closedError == nil, let message = try? encoder.encode(OutgoingResult(id: id, result: result)) else { return }
        try? send(message + Data([0x0A]))
    }

    public func respond(to id: RequestID, errorCode: Int, message text: String) {
        let body = OutgoingError.Body(code: errorCode, message: text)
        guard closedError == nil, let message = try? encoder.encode(OutgoingError(id: id, error: body)) else { return }
        try? send(message + Data([0x0A]))
    }

    // MARK: Incoming

    /// Routes one complete message: replies resume their request, anything else is returned to the caller.
    public func receive(_ message: Data) -> Incoming? {
        guard let header = try? decoder.decode(IncomingHeader.self, from: message) else {
            Log.info("acp: dropped a message that is not JSON-RPC")
            return nil
        }
        switch (header.method, header.id) {
        case (let method?, let id?):
            return .request(id: id, method: method, message: message)
        case (let method?, nil):
            return .notification(method: method, message: message)
        case (nil, .number(let id)?):
            pending.removeValue(forKey: id)?.resume(returning: message)
            return nil
        default:
            return nil
        }
    }

    /// Fails every outstanding request. Later calls throw `error`.
    public func close(_ error: ACPError = .disconnected) {
        guard closedError == nil else { return }
        closedError = error
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
