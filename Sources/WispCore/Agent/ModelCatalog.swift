/// The models grok offers this login, and the reasoning-effort levels each accepts.
public struct ModelCatalog: Sendable, Equatable {
    public struct Model: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Effort levels from `initialize`; empty when grok did not list them for this model.
        public let efforts: [String]
        public let defaultEffort: String?

        public init(id: String, name: String, efforts: [String] = [], defaultEffort: String? = nil) {
            self.id = id
            self.name = name
            self.efforts = efforts
            self.defaultEffort = defaultEffort
        }
    }

    /// Used until grok reports a model's levels; every model with reasoning accepts these.
    static let fallbackEfforts = ["low", "medium", "high", "xhigh"]

    public private(set) var models: [Model]
    /// The default model from the user's Grok Build config.
    public private(set) var defaultModelID: String?
    /// Levels learned from live sessions, which list them even when `initialize` does not.
    private var sessionEfforts: [String: [String]] = [:]

    public init(models: [Model] = [], defaultModelID: String? = nil) {
        self.models = models
        self.defaultModelID = defaultModelID
    }

    init(_ result: InitializeResult) {
        let state = result.meta?.modelState
        self.init(
            models: (state?.availableModels ?? []).map { entry in
                Model(
                    id: entry.modelId,
                    name: entry.name ?? entry.modelId,
                    efforts: (entry.meta?.reasoningEfforts ?? []).map(\.value),
                    defaultEffort: entry.meta?.reasoningEffort)
            },
            defaultModelID: state?.currentModelId)
    }

    public func name(of modelID: String) -> String {
        models.first { $0.id == modelID }?.name ?? modelID
    }

    public func efforts(for modelID: String) -> [String] {
        if let listed = models.first(where: { $0.id == modelID })?.efforts, !listed.isEmpty { return listed }
        return sessionEfforts[modelID] ?? Self.fallbackEfforts
    }

    /// Keeps `effort` when the model accepts it; otherwise prefers `low` (quick answers), then the model's default.
    public func effort(_ effort: String, adjustedFor modelID: String) -> String {
        let accepted = efforts(for: modelID)
        guard !effort.isEmpty, !accepted.contains(effort) else { return effort }
        if accepted.contains("low") { return "low" }
        return models.first { $0.id == modelID }?.defaultEffort ?? accepted.first ?? effort
    }

    /// Records the effort levels a session reported for its current model.
    public mutating func learn(from options: [ConfigOption]) {
        guard let model = options.first(where: { $0.id == "model" })?.currentValue,
              let efforts = options.first(where: { $0.id == "reasoning_effort" })?.values,
              !efforts.isEmpty
        else { return }
        sessionEfforts[model] = efforts
    }
}
