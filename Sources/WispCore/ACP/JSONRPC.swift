import Foundation

/// A JSON-RPC request ID; the agent may use numbers or strings for the requests it sends us.
public enum RequestID: Hashable, Sendable, Codable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

public enum ACPError: LocalizedError, Equatable, Sendable {
    /// The agent replied with a JSON-RPC error.
    case rpc(code: Int, message: String)
    /// The agent process went away before answering.
    case disconnected
    case missingResult(method: String)

    public var errorDescription: String? {
        switch self {
        case .rpc(_, let message): message
        case .disconnected: "Lost the connection to Grok."
        case .missingResult(let method): "Grok sent an empty reply to \(method)."
        }
    }
}

// MARK: Wire envelopes

struct OutgoingRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

struct OutgoingNotification<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

struct OutgoingResult<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: RequestID
    let result: Result
}

struct OutgoingError: Encodable {
    struct Body: Encodable {
        let code: Int
        let message: String
    }

    let jsonrpc = "2.0"
    let id: RequestID
    let error: Body
}

/// Enough of any incoming message to route it.
struct IncomingHeader: Decodable {
    let id: RequestID?
    let method: String?
}

struct IncomingError: Decodable {
    struct Body: Decodable {
        let code: Int
        let message: String
        let data: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(Int.self, forKey: .code)
            message = try container.decode(String.self, forKey: .message)
            data = try? container.decodeIfPresent(String.self, forKey: .data)
        }

        private enum CodingKeys: String, CodingKey { case code, message, data }
    }

    let error: Body?
}

struct IncomingResult<Result: Decodable>: Decodable {
    let result: Result?
}

struct IncomingParams<Params: Decodable>: Decodable {
    let params: Params
}

/// For requests whose reply carries nothing Wisp needs.
public struct EmptyResult: Codable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }

    private enum CodingKeys: CodingKey {}
}
