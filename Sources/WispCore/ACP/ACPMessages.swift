import Foundation

// The subset of the Agent Client Protocol (https://agentclientprotocol.com) that Wisp uses, plus the
// `_x.ai/*` extensions Grok Build sends. Decoding is lenient: unknown fields are ignored and unknown
// update kinds decode to `.other`, so a newer grok never breaks the panel.

// MARK: initialize

struct InitializeParams: Encodable, Sendable {
    struct ClientCapabilities: Encodable, Sendable {
        struct FileSystem: Encodable, Sendable {
            let readTextFile = false
            let writeTextFile = false
        }

        let fs = FileSystem()
        let terminal = false
    }

    struct ClientInfo: Encodable, Sendable {
        let name: String
        let version: String
    }

    let protocolVersion = 1
    let clientCapabilities = ClientCapabilities()
    let clientInfo: ClientInfo
}

struct InitializeResult: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let modelState: ModelState?
    }

    struct ModelState: Decodable, Sendable {
        let currentModelId: String?
        let availableModels: [AvailableModel]?
    }

    struct AvailableModel: Decodable, Sendable {
        struct Meta: Decodable, Sendable {
            struct Effort: Decodable, Sendable {
                let value: String
            }

            let reasoningEffort: String?
            let reasoningEfforts: [Effort]?
        }

        let modelId: String
        let name: String?
        let meta: Meta?

        enum CodingKeys: String, CodingKey {
            case modelId, name
            case meta = "_meta"
        }
    }

    let meta: Meta?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

// MARK: Sessions

struct NewSessionParams: Encodable, Sendable {
    struct Meta: Encodable, Sendable {
        let yoloMode: Bool
        let rules: String
    }

    let cwd: String
    let mcpServers: [String] = []
    let meta: Meta

    enum CodingKeys: String, CodingKey {
        case cwd, mcpServers
        case meta = "_meta"
    }
}

public struct NewSessionResult: Decodable, Sendable {
    public let sessionId: String
    public let configOptions: [ConfigOption]?
}

struct SessionParams: Encodable, Sendable {
    let sessionId: String
}

struct SetConfigOptionParams: Encodable, Sendable {
    let sessionId: String
    let configId: String
    let value: String
}

struct SetConfigOptionResult: Decodable, Sendable {
    let configOptions: [ConfigOption]?
}

/// A session setting such as `model` or `reasoning_effort`, with the values it accepts.
public struct ConfigOption: Decodable, Sendable, Equatable {
    public let id: String
    public let currentValue: String?
    public let values: [String]

    public init(id: String, currentValue: String?, values: [String]) {
        self.id = id
        self.currentValue = currentValue
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        struct Choice: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try? container.decodeIfPresent(String.self, forKey: .value)
            }

            enum CodingKeys: String, CodingKey { case value }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        currentValue = try? container.decodeIfPresent(String.self, forKey: .currentValue)
        values = ((try? container.decodeIfPresent([Choice].self, forKey: .options)) ?? []).compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case id, currentValue, options }
}

struct PromptParams: Encodable, Sendable {
    struct TextBlock: Encodable, Sendable {
        let type = "text"
        let text: String
    }

    let sessionId: String
    let prompt: [TextBlock]
}

public struct PromptResult: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let modelId: String?
    }

    public let stopReason: String?
    let meta: Meta?

    /// The model that answered, as reported by grok.
    public var modelID: String? { meta?.modelId }

    enum CodingKeys: String, CodingKey {
        case stopReason
        case meta = "_meta"
    }
}

// MARK: Agent → client

struct PermissionRequest: Decodable, Sendable {
    struct Option: Decodable, Sendable {
        let optionId: String
        let kind: String?
    }

    let options: [Option]
}

struct PermissionResponse: Encodable, Sendable {
    struct Outcome: Encodable, Sendable {
        let outcome: String
        let optionId: String?
    }

    let outcome: Outcome
}

// MARK: Session updates

/// A `session/update` or `_x.ai/session_notification` for one session.
public struct SessionNotification: Decodable, Sendable {
    public let sessionId: String
    public let update: SessionUpdate
}

public enum SessionUpdate: Decodable, Sendable, Equatable {
    case messageChunk(String)
    case thoughtChunk(String)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case retry(RetryState)
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        let single = try decoder.singleValueContainer()
        switch kind {
        case "agent_message_chunk":
            self = .messageChunk((try? container.decode(TextContent.self, forKey: .content).text) ?? "")
        case "agent_thought_chunk":
            self = .thoughtChunk((try? container.decode(TextContent.self, forKey: .content).text) ?? "")
        case "tool_call":
            self = .toolCall(try single.decode(ToolCall.self))
        case "tool_call_update":
            self = .toolCallUpdate(try single.decode(ToolCallUpdate.self))
        case "retry_state":
            self = .retry(try single.decode(RetryState.self))
        default:
            self = .other(kind)
        }
    }

    private struct TextContent: Decodable {
        let text: String?
    }

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, content
    }
}

public struct ToolCall: Decodable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let status: String?
    public let input: ToolInput

    public init(id: String, title: String?, status: String?, input: ToolInput = ToolInput()) {
        self.id = id
        self.title = title
        self.status = status
        self.input = input
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .toolCallId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        input = (try? container.decodeIfPresent(ToolInput.self, forKey: .rawInput)) ?? ToolInput()
    }

    enum CodingKeys: String, CodingKey { case toolCallId, title, status, rawInput }
}

public struct ToolCallUpdate: Decodable, Sendable, Equatable {
    public let id: String
    public let title: String?
    public let status: String?

    public init(id: String, title: String?, status: String?) {
        self.id = id
        self.title = title
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .toolCallId)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
    }

    enum CodingKeys: String, CodingKey { case toolCallId, title, status }
}

/// The few tool arguments worth showing in a one-line summary.
public struct ToolInput: Decodable, Sendable, Equatable {
    public var command: String?
    public var query: String?
    public var path: String?
    public var url: String?

    public init(command: String? = nil, query: String? = nil, path: String? = nil, url: String? = nil) {
        self.command = command
        self.query = query
        self.path = path
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        command = string(.command)
        query = string(.query) ?? string(.pattern)
        path = string(.targetFile) ?? string(.filePath) ?? string(.path) ?? string(.targetDirectory)
        url = string(.url)
    }

    enum CodingKeys: String, CodingKey {
        case command, query, pattern, path, url
        case targetFile = "target_file"
        case filePath = "file_path"
        case targetDirectory = "target_directory"
    }
}

/// Grok's report on retrying a failed model call.
public enum RetryState: Decodable, Sendable, Equatable {
    case retrying(attempt: Int, maxRetries: Int?)
    case exhausted(reason: String)
    case failed(message: String, isAuthError: Bool)
    case other

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        func int(_ key: CodingKeys) -> Int? { try? container.decodeIfPresent(Int.self, forKey: key) }
        switch string(.type) {
        case "retrying":
            self = .retrying(attempt: int(.attempt) ?? 1, maxRetries: int(.maxRetriesSnake) ?? int(.maxRetries))
        case "exhausted":
            self = .exhausted(reason: string(.reason) ?? "Grok is unavailable right now.")
        case "failed":
            let type = string(.errorTypeSnake) ?? string(.errorType)
            self = .failed(message: string(.message) ?? "The request failed.", isAuthError: type == "auth")
        default:
            self = .other
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, attempt, reason, message, maxRetries, errorType
        case maxRetriesSnake = "max_retries"
        case errorTypeSnake = "error_type"
    }
}
