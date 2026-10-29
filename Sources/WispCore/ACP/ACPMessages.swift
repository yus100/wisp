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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A malformed catalog must not fail the handshake; the update notification can replace it.
            modelState = (try? container.decodeIfPresent(ModelState.self, forKey: .modelState)) ?? nil
        }

        private enum CodingKeys: String, CodingKey {
            case modelState
        }
    }

    struct ModelState: Decodable, Sendable {
        let currentModelId: String?
        let availableModels: [AvailableModel]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            currentModelId = (try? container.decodeIfPresent(String.self, forKey: .currentModelId)) ?? nil
            availableModels = Self.models(in: container)
        }

        /// One bad row is dropped. grok does the same ("ignoring malformed value") instead of failing the list.
        private static func models(in container: KeyedDecodingContainer<CodingKeys>) -> [AvailableModel] {
            guard var rows = try? container.nestedUnkeyedContainer(forKey: .availableModels) else { return [] }
            var models: [AvailableModel] = []
            while !rows.isAtEnd {
                guard let row = try? rows.decode(LossyDecodable<AvailableModel>.self) else { break }
                if let model = row.value { models.append(model) }
            }
            return models
        }

        private enum CodingKeys: String, CodingKey {
            case currentModelId, availableModels
        }
    }

    struct AvailableModel: Decodable, Sendable {
        struct Meta: Decodable, Sendable {
            struct Effort: Decodable, Sendable, Equatable {
                let value: String
                let label: String?

                init(from decoder: Decoder) throws {
                    // A string (`"low"`) or an object (`{"value":"max","label":"Max"}`). One container:
                    // asking for both a keyed and a single-value container on the same decoder traps.
                    let container = try decoder.singleValueContainer()
                    if let value = try? container.decode(String.self), !value.isEmpty {
                        self.value = value
                        label = nil
                        return
                    }
                    let object = try container.decode(Object.self)
                    let value = object.value ?? object.id
                    guard let value, !value.isEmpty else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: decoder.codingPath, debugDescription: "reasoning effort has no value"))
                    }
                    self.value = value
                    label = object.label?.isEmpty == false ? object.label : nil
                }

                private struct Object: Decodable {
                    let id: String?
                    let value: String?
                    let label: String?
                }
            }

            let reasoningEffort: String?
            /// True when grok sent `reasoningEfforts`, even as an empty array (older agents).
            let effortsKeyPresent: Bool
            let reasoningEfforts: [Effort]
            let supportsReasoningEffort: Bool?
            /// Section title from `_meta.group`, `_meta.vendor`, or `_meta.provider` when grok sends one.
            let group: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                reasoningEffort = (try? container.decodeIfPresent(String.self, forKey: .reasoningEffort)) ?? nil
                supportsReasoningEffort = (try? container.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort)) ?? nil
                effortsKeyPresent = container.contains(.reasoningEfforts)
                reasoningEfforts = Self.efforts(in: container)
                group = Self.group(in: container)
            }

            private static func efforts(in container: KeyedDecodingContainer<CodingKeys>) -> [Effort] {
                guard var rows = try? container.nestedUnkeyedContainer(forKey: .reasoningEfforts) else { return [] }
                var efforts: [Effort] = []
                while !rows.isAtEnd {
                    guard let row = try? rows.decode(LossyDecodable<Effort>.self) else { break }
                    if let effort = row.value, !efforts.contains(where: { $0.value == effort.value }) {
                        efforts.append(effort)
                    }
                }
                return efforts
            }

            private static func group(in container: KeyedDecodingContainer<CodingKeys>) -> String? {
                for key in [CodingKeys.group, .vendor, .provider] {
                    if let name = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil, !name.isEmpty {
                        return name
                    }
                    if let named = (try? container.decodeIfPresent(NamedGroup.self, forKey: key)) ?? nil,
                        let name = named.displayName ?? named.name, !name.isEmpty
                    {
                        return name
                    }
                }
                return nil
            }

            private struct NamedGroup: Decodable {
                let name: String?
                let displayName: String?
            }

            private enum CodingKeys: String, CodingKey {
                case reasoningEffort, reasoningEfforts, supportsReasoningEffort, group, vendor, provider
            }
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

/// A catalog push. grok sends this as `_x.ai/models/update` once the remote list (including third-party
/// models) has loaded, and again after a login or cache refresh. The body is a model state, or that state
/// nested under `modelState` / `_meta.modelState`.
struct ModelsUpdate: Sendable {
    let state: InitializeResult.ModelState

    static func decode(message: Data) -> ModelsUpdate? {
        guard let root = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
            let params = root["params"] as? [String: Any]
        else { return nil }
        let payload =
            params["modelState"] as? [String: Any]
            ?? (params["_meta"] as? [String: Any])?["modelState"] as? [String: Any]
            ?? params
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let state = try? JSONDecoder().decode(InitializeResult.ModelState.self, from: data)
        else { return nil }
        return ModelsUpdate(state: state)
    }
}

/// Decodes one array element and keeps going when that element is malformed.
private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
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
    /// The catalog at session-open time, when grok includes one. A bad payload is ignored.
    let models: InitializeResult.ModelState?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        configOptions = try container.decodeIfPresent([ConfigOption].self, forKey: .configOptions)
        models = (try? container.decodeIfPresent(InitializeResult.ModelState.self, forKey: .models)) ?? nil
    }

    private enum CodingKeys: String, CodingKey { case sessionId, configOptions, models }
}

struct SessionParams: Encodable, Sendable {
    let sessionId: String
}

struct LoadSessionParams: Encodable, Sendable {
    let sessionId: String
    let cwd: String
    let mcpServers: [String] = []
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
    /// Display names keyed by option value, when grok sent them (`"xhigh"` → `"Extra High"`).
    public let labels: [String: String]

    public init(id: String, currentValue: String?, values: [String], labels: [String: String] = [:]) {
        self.id = id
        self.currentValue = currentValue
        self.values = values
        self.labels = labels
    }

    public init(from decoder: Decoder) throws {
        struct Choice: Decodable {
            let value: String?
            let name: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try? container.decodeIfPresent(String.self, forKey: .value)
                name = try? container.decodeIfPresent(String.self, forKey: .name)
            }

            enum CodingKeys: String, CodingKey { case value, name }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        currentValue = try? container.decodeIfPresent(String.self, forKey: .currentValue)
        let choices = (try? container.decodeIfPresent([Choice].self, forKey: .options)) ?? []
        values = choices.compactMap(\.value)
        labels = Dictionary(
            choices.compactMap { choice -> (String, String)? in
                guard let value = choice.value, let name = choice.name, !name.isEmpty else { return nil }
                return (value, name)
            },
            uniquingKeysWith: { _, latest in latest })
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
    /// The slash commands the session accepts: built-ins, skills, and saved workflows.
    case availableCommands([SlashCommand])
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
        case "available_commands_update":
            let commands = (try? container.decode([LenientCommand].self, forKey: .availableCommands)) ?? []
            self = .availableCommands(commands.compactMap(\.command))
        default:
            self = .other(kind)
        }
    }

    private struct TextContent: Decodable {
        let text: String?
    }

    /// One malformed entry must not drop the whole list.
    private struct LenientCommand: Decodable {
        let command: SlashCommand?

        init(from decoder: Decoder) throws {
            command = try? SlashCommand(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, content, availableCommands
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

/// The agent's report on retrying a failed model call.
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
            self = .exhausted(reason: string(.reason) ?? "The model is unavailable right now.")
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
