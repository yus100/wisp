/// The models grok offers this login, and the reasoning-effort levels each accepts.
public struct ModelCatalog: Sendable, Equatable {
    public struct Model: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Effort levels from the catalog, in grok's order. Empty when this model doesn't list any.
        public let efforts: [String]
        public let defaultEffort: String?
        /// `true` when the model lists reasoning levels, `false` when its metadata has none,
        /// `nil` when an older catalog left it unspecified (the fallback list applies until a session reports).
        public let supportsReasoning: Bool?
        /// Menu section, when grok sent `_meta.group`, `vendor`, or `provider`.
        public let group: String?
        /// Provider labels for `efforts` (`"xhigh"` → `"Extra High"`). Missing labels use `fallbackEffortLabel`.
        public let effortLabels: [String: String]

        public init(
            id: String, name: String, efforts: [String] = [], defaultEffort: String? = nil,
            supportsReasoning: Bool? = nil, group: String? = nil, effortLabels: [String: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.efforts = efforts
            self.defaultEffort = defaultEffort
            self.supportsReasoning = supportsReasoning
            self.group = group
            self.effortLabels = effortLabels
        }
    }

    /// Used until grok reports a model's levels. Not used for a model that doesn't advertise reasoning.
    static let fallbackEfforts = ["low", "medium", "high", "xhigh"]

    public private(set) var models: [Model]
    /// The default model from the user's Grok Build config.
    public private(set) var defaultModelID: String?
    /// Levels learned from live sessions, which list them even when `initialize` does not.
    private var sessionEfforts: [String: [String]] = [:]
    private var sessionEffortLabels: [String: [String: String]] = [:]

    public init(models: [Model] = [], defaultModelID: String? = nil) {
        self.models = models
        self.defaultModelID = defaultModelID
    }

    init(_ result: InitializeResult) {
        self.init(result.meta?.modelState)
    }

    init(_ state: InitializeResult.ModelState?) {
        var seen: Set<String> = []
        let models = (state?.availableModels ?? []).compactMap { entry -> Model? in
            let id = entry.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let rawName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (rawName?.isEmpty == false ? rawName : nil) ?? id
            var values: [String] = []
            var labels: [String: String] = [:]
            for effort in entry.meta?.reasoningEfforts ?? [] {
                values.append(effort.value)
                if let label = effort.label { labels[effort.value] = label }
            }
            return Model(
                id: id, name: name, efforts: values, defaultEffort: entry.meta?.reasoningEffort,
                supportsReasoning: Self.supportsReasoning(entry.meta, hasEfforts: !values.isEmpty),
                group: entry.meta?.group, effortLabels: labels)
        }
        let defaultID = state?.currentModelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(models: models, defaultModelID: defaultID?.isEmpty == false ? defaultID : nil)
    }

    /// Replaces the catalog with a later snapshot. An empty list is ignored so a refresh that fails
    /// mid-fetch cannot wipe models grok already delivered. Session-learned efforts are kept.
    mutating func apply(modelState: InitializeResult.ModelState) {
        var incoming = ModelCatalog(modelState)
        guard !incoming.models.isEmpty else { return }
        incoming.sessionEfforts = sessionEfforts
        incoming.sessionEffortLabels = sessionEffortLabels
        self = incoming
    }

    public func contains(_ modelID: String) -> Bool {
        models.contains { $0.id == modelID }
    }

    /// The saved id when it is still offered, otherwise grok's default.
    public func resolvedModelID(_ saved: String) -> String? {
        if !saved.isEmpty, contains(saved) { return saved }
        guard let defaultModelID, !defaultModelID.isEmpty else { return nil }
        return defaultModelID
    }

    public func name(of modelID: String) -> String {
        models.first { $0.id == modelID }?.name ?? modelID
    }

    /// The row title. Two models that share a display name (grok does this) keep the id so they can be told apart.
    public func menuTitle(of modelID: String) -> String {
        let name = name(of: modelID)
        let same = models.filter { $0.name == name }
        guard same.count > 1, same.contains(where: { $0.id == modelID }) else { return name }
        return "\(name) · \(modelID)"
    }

    public func efforts(for modelID: String) -> [String] {
        if let model = models.first(where: { $0.id == modelID }) {
            // A model grok described as having no reasoning control stays that way even if a session
            // once reported levels for it.
            if model.supportsReasoning == false { return [] }
            if !model.efforts.isEmpty { return model.efforts }
            if let learned = sessionEfforts[modelID], !learned.isEmpty { return learned }
            return Self.fallbackEfforts
        }
        return sessionEfforts[modelID] ?? Self.fallbackEfforts
    }

    public func effortLabel(_ effort: String, for modelID: String) -> String {
        if let label = models.first(where: { $0.id == modelID })?.effortLabels[effort], !label.isEmpty { return label }
        if let label = sessionEffortLabels[modelID]?[effort], !label.isEmpty { return label }
        return Self.fallbackEffortLabel(effort)
    }

    public static func fallbackEffortLabel(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    /// Keeps `effort` when the model accepts it; otherwise prefers `low` (quick answers), then the model's default.
    /// A model with no reasoning control leaves `effort` unchanged, so picking it does not forget the preference.
    public func effort(_ effort: String, adjustedFor modelID: String) -> String {
        let accepted = efforts(for: modelID)
        guard !accepted.isEmpty else { return effort }
        guard !effort.isEmpty, !accepted.contains(effort) else { return effort }
        if accepted.contains("low") { return "low" }
        return models.first { $0.id == modelID }?.defaultEffort ?? accepted.first ?? effort
    }

    /// What to put on the live session so it matches the chip.
    ///
    /// A saved id that the catalog lists is sent as itself. One that disappeared is sent as grok's
    /// default, so the session does not keep answering with a model the menu no longer offers.
    /// An effort the effective model does not accept is replaced with one it does; a model with no
    /// reasoning control is left unset.
    public func settings(savedModel: String, savedEffort: String) -> (model: String?, effort: String?) {
        let model: String?
        if !savedModel.isEmpty, contains(savedModel) {
            model = savedModel
        } else if !savedModel.isEmpty, !models.isEmpty, let defaultModelID, !defaultModelID.isEmpty {
            model = defaultModelID
        } else {
            model = nil
        }
        guard let target = model ?? resolvedModelID(savedModel) else { return (model, nil) }
        let accepted = efforts(for: target)
        guard !savedEffort.isEmpty else { return (model, nil) }
        if accepted.contains(savedEffort) { return (model, savedEffort) }
        let adjusted = effort(savedEffort, adjustedFor: target)
        guard !adjusted.isEmpty, accepted.contains(adjusted) else { return (model, nil) }
        return (model, adjusted)
    }

    /// Records the effort levels a session reported for its current model.
    /// An empty list, or a model that does not support reasoning, drops anything learned earlier.
    public mutating func learn(from options: [ConfigOption]) {
        guard let model = options.first(where: { $0.id == "model" })?.currentValue,
            let effort = options.first(where: { $0.id == "reasoning_effort" })
        else { return }
        let unsupported = models.first { $0.id == model }?.supportsReasoning == false
        guard !unsupported, !effort.values.isEmpty else {
            sessionEfforts[model] = nil
            sessionEffortLabels[model] = nil
            return
        }
        sessionEfforts[model] = effort.values
        if !effort.labels.isEmpty { sessionEffortLabels[model] = effort.labels }
    }

    /// `nil` keeps the historical fallback. `false` means grok described the model and did not give it reasoning.
    private static func supportsReasoning(_ meta: InitializeResult.AvailableModel.Meta?, hasEfforts: Bool) -> Bool? {
        guard let meta else { return nil }
        if meta.supportsReasoningEffort == false { return false }
        if meta.supportsReasoningEffort == true || hasEfforts { return true }
        if meta.effortsKeyPresent || meta.reasoningEffort != nil { return nil }
        return false
    }
}
