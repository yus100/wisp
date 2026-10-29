import Foundation
import Testing

@testable import WispCore

/// Runs `GrokAgent` against `Fixtures/fake-grok-agent.py`: real process, pipes, framing, and ordering.
@MainActor
@Suite struct GrokAgentTests {
    @MainActor final class Recorder {
        var updates: [SessionUpdate] = []
        var exits: [Int32] = []
    }

    func startAgent(
        environment extra: [String: String] = [:], startTimeout: Duration = .seconds(30)
    ) async throws -> (GrokAgent, Recorder) {
        let source = try #require(
            Bundle.module.url(forResource: "fake-grok-agent", withExtension: "py", subdirectory: "Fixtures"))
        let executable = FileManager.default.temporaryDirectory.appending(path: "fake-grok-\(UUID().uuidString).py")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let agent = GrokAgent(
            launch: .init(
                executable: executable,
                environment: ProcessInfo.processInfo.environment.merging(extra) { $1 },
                workingDirectory: FileManager.default.temporaryDirectory,
                clientVersion: "test",
                startTimeout: startTimeout))
        let recorder = Recorder()
        agent.onSessionUpdate = { recorder.updates.append($0.update) }
        agent.onUnexpectedExit = { recorder.exits.append($0) }
        try await agent.start()
        return (agent, recorder)
    }

    @Test func handshakeLoadsTheModelCatalog() async throws {
        let (agent, _) = try await startAgent()
        defer { agent.stop() }
        #expect(agent.catalog.defaultModelID == "grok-test")
        #expect(agent.catalog.models.map(\.id) == ["grok-test", "claude-test"])
        #expect(agent.catalog.efforts(for: "grok-test") == ["low", "high"])
    }

    @Test func promptStreamsEveryUpdateBeforeReturning() async throws {
        let (agent, recorder) = try await startAgent()
        defer { agent.stop() }
        let session = try await agent.newSession(in: "/tmp", rules: "be brief")
        #expect(session.sessionId == "session-1")

        let result = try await agent.prompt("hello", in: session.sessionId)
        #expect(result.stopReason == "end_turn")
        #expect(result.modelID == "grok-test")
        #expect(
            recorder.updates == [
                .messageChunk("Hello "),
                .toolCall(
                    ToolCall(id: "t1", title: "run_terminal_command", status: "pending", input: ToolInput(command: "ls ~"))),
                .toolCallUpdate(ToolCallUpdate(id: "t1", title: nil, status: "completed")),
                .other("plan"),
                .messageChunk("world"),
            ])
    }

    @Test func approvesPermissionRequestsAndDeclinesUnsupportedOnes() async throws {
        let (agent, recorder) = try await startAgent()
        defer { agent.stop() }
        let session = try await agent.newSession(in: "/tmp", rules: "")
        _ = try await agent.prompt("permit", in: session.sessionId)
        _ = try await agent.prompt("permit-always-only", in: session.sessionId)
        _ = try await agent.prompt("fs", in: session.sessionId)
        #expect(
            recorder.updates == [
                .messageChunk("approved:once"), .messageChunk("outcome:cancelled"), .messageChunk("error:-32601"),
            ])
    }

    @Test func switchingModelsLearnsTheirEffortLevels() async throws {
        let (agent, _) = try await startAgent()
        defer { agent.stop() }
        let session = try await agent.newSession(in: "/tmp", rules: "")
        #expect(agent.catalog.efforts(for: "claude-test") == ModelCatalog.fallbackEfforts)
        try await agent.setOption("model", to: "claude-test", in: session.sessionId)
        #expect(agent.catalog.efforts(for: "claude-test") == ["minimal", "low", "medium", "high", "xhigh"])
        let result = try await agent.prompt("hello", in: session.sessionId)
        #expect(result.modelID == "claude-test")
        await agent.close(session.sessionId)
    }

    @Test func loadReattachesASavedSession() async throws {
        let (agent, recorder) = try await startAgent()
        defer { agent.stop() }
        try await agent.load("session-1", in: "/tmp")
        try await waitFor { await MainActor.run { recorder.updates == [.messageChunk("(replayed history)")] } }
    }

    @Test func crashFailsTheTurnAndReportsTheExit() async throws {
        let (agent, recorder) = try await startAgent()
        let session = try await agent.newSession(in: "/tmp", rules: "")
        await #expect(throws: ACPError.disconnected) { try await agent.prompt("crash", in: session.sessionId) }
        try await waitFor { await MainActor.run { !recorder.exits.isEmpty } }
        #expect(recorder.exits == [3])
        #expect(!agent.isRunning)
        await #expect(throws: ACPError.disconnected) { try await agent.prompt("hello", in: session.sessionId) }
    }

    @Test func aHungHandshakeTimesOutAndStopsTheProcess() async throws {
        let start = ContinuousClock.now
        await #expect(throws: TimedOut(what: "grok to start")) {
            _ = try await startAgent(environment: ["FAKE_AGENT_HANG": "1"], startTimeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func modelUpdateReplacesAPartialCatalogAndIgnoresAnEmptyOne() async throws {
        let (agent, _) = try await startAgent(environment: ["FAKE_MODELS_UPDATE": "1"])
        defer { agent.stop() }
        try await waitFor { await MainActor.run { agent.catalog.contains("gemini-test") } }
        let catalog = await MainActor.run { agent.catalog }
        #expect(catalog.models.map(\.id) == ["grok-test", "claude-opus", "gemini-test"])
        #expect(catalog.models.map(\.group) == ["Grok", "Anthropic", "Google"])
        #expect(catalog.efforts(for: "claude-opus") == ["medium", "max"])
        #expect(catalog.effortLabel("max", for: "claude-opus") == "Max")
        #expect(catalog.effortLabel("xhigh", for: "grok-test") == "Extra High")
        #expect(catalog.efforts(for: "gemini-test").isEmpty)
        #expect(catalog.defaultModelID == "grok-test")
    }

    @Test func stopIsNotReportedAsACrash() async throws {
        let (agent, recorder) = try await startAgent()
        agent.stop()
        try await waitFor { await MainActor.run { !agent.isRunning } }
        #expect(recorder.exits.isEmpty)
    }
}

@Suite struct ModelCatalogTests {
    let catalog = ModelCatalog(
        models: [
            .init(id: "grok", name: "Grok", efforts: ["xhigh", "high", "medium"], defaultEffort: "high"),
            .init(id: "claude", name: "Claude", efforts: [], defaultEffort: "high"),
        ], defaultModelID: "grok")

    @Test func effortsFallBackUntilASessionReportsThem() {
        var catalog = catalog
        #expect(catalog.efforts(for: "claude") == ModelCatalog.fallbackEfforts)
        catalog.learn(from: [
            ConfigOption(id: "model", currentValue: "claude", values: []),
            ConfigOption(
                id: "reasoning_effort", currentValue: "low", values: ["minimal", "low"], labels: ["minimal": "Least"]),
        ])
        #expect(catalog.efforts(for: "claude") == ["minimal", "low"])
        #expect(catalog.effortLabel("minimal", for: "claude") == "Least")
        #expect(catalog.efforts(for: "grok") == ["xhigh", "high", "medium"])
        catalog.learn(from: [
            ConfigOption(id: "model", currentValue: "claude", values: []),
            ConfigOption(id: "reasoning_effort", currentValue: nil, values: []),
        ])
        #expect(catalog.efforts(for: "claude") == ModelCatalog.fallbackEfforts)
    }

    @Test func modelsWithoutReasoningIgnoreSessionLevels() {
        var catalog = ModelCatalog(
            models: [.init(id: "gemini", name: "Gemini", supportsReasoning: false, group: "Google")],
            defaultModelID: "gemini")
        catalog.learn(from: [
            ConfigOption(id: "model", currentValue: "gemini", values: []),
            ConfigOption(id: "reasoning_effort", currentValue: "low", values: ["low", "high"], labels: ["low": "Low"]),
        ])
        #expect(catalog.efforts(for: "gemini").isEmpty)
        #expect(catalog.settings(savedModel: "gemini", savedEffort: "high") == (model: "gemini", effort: nil))
    }

    @Test func sessionSettingsFollowTheChipWhenTheCatalogChanges() {
        let catalog = ModelCatalog(
            models: [
                .init(id: "grok", name: "Grok", efforts: ["low", "high"], defaultEffort: "high", supportsReasoning: true),
                .init(
                    id: "claude", name: "Claude", efforts: ["medium", "max"], defaultEffort: "medium", supportsReasoning: true),
            ],
            defaultModelID: "grok")
        #expect(catalog.settings(savedModel: "claude", savedEffort: "medium") == (model: "claude", effort: "medium"))
        #expect(catalog.settings(savedModel: "claude", savedEffort: "xhigh") == (model: "claude", effort: "medium"))
        #expect(catalog.settings(savedModel: "retired", savedEffort: "high") == (model: "grok", effort: "high"))
        #expect(catalog.settings(savedModel: "retired", savedEffort: "xhigh") == (model: "grok", effort: "low"))
        #expect(catalog.settings(savedModel: "", savedEffort: "high") == (model: nil, effort: "high"))
    }

    @Test func effortAdjustsToWhatTheModelAccepts() {
        #expect(catalog.effort("medium", adjustedFor: "grok") == "medium")
        #expect(catalog.effort("low", adjustedFor: "grok") == "high")
        #expect(catalog.effort("minimal", adjustedFor: "claude") == "low")
        #expect(catalog.effort("", adjustedFor: "grok") == "")
        #expect(catalog.effortLabel("xhigh", for: "grok") == "Extra high")
    }

    @Test func namesFallBackToIDs() {
        #expect(catalog.name(of: "grok") == "Grok")
        #expect(catalog.name(of: "unknown-model") == "unknown-model")
    }

    @Test func thirdPartyCatalogKeepsLabelsGroupsAndDropsBadRows() throws {
        let result = try JSONDecoder().decode(
            InitializeResult.self,
            from: Data(
                #"""
                {"_meta":{"modelState":{"currentModelId":" grok-4.7 ","availableModels":[
                  {"modelId":"grok-4.7","name":"Grok 4.7","_meta":{"supportsReasoningEffort":true,"reasoningEffort":"high",
                    "reasoningEfforts":["low",{"value":"xhigh","label":"Extra High"},{"label":"skip"},5]}},
                  {"name":"malformed"},
                  {"modelId":"claude-opus-5-5","name":"Claude Opus 5.5","_meta":{"group":"Anthropic",
                    "reasoningEfforts":[{"id":"max","label":"Max"}]}},
                  {"modelId":"gemini-4-argon","name":"Gemini 4 Argon","_meta":{"vendor":{"displayName":"Google"}}},
                  {"modelId":"composer-2.5","name":"Composer 2.5","_meta":{"supportsReasoningEffort":false}},
                  {"modelId":"cursor-helios-alpha","name":"Cursor Helios Alpha"},
                  {"modelId":"cursor-helios-alpha-staging","name":"Cursor Helios Alpha"},
                  {"modelId":"grok-4.7","name":"Duplicate"}
                ]}}}
                """#.utf8))
        let decoded = ModelCatalog(result)
        #expect(decoded.defaultModelID == "grok-4.7")
        #expect(
            decoded.models.map(\.id) == [
                "grok-4.7", "claude-opus-5-5", "gemini-4-argon", "composer-2.5", "cursor-helios-alpha",
                "cursor-helios-alpha-staging",
            ])
        #expect(decoded.efforts(for: "grok-4.7") == ["low", "xhigh"])
        #expect(decoded.effortLabel("xhigh", for: "grok-4.7") == "Extra High")
        #expect(decoded.efforts(for: "claude-opus-5-5") == ["max"])
        #expect(decoded.effortLabel("max", for: "claude-opus-5-5") == "Max")
        #expect(decoded.models.first { $0.id == "claude-opus-5-5" }?.group == "Anthropic")
        #expect(decoded.models.first { $0.id == "gemini-4-argon" }?.group == "Google")
        #expect(decoded.efforts(for: "gemini-4-argon").isEmpty)
        #expect(decoded.efforts(for: "composer-2.5").isEmpty)
        #expect(decoded.effort("low", adjustedFor: "composer-2.5") == "low")
        #expect(decoded.menuTitle(of: "cursor-helios-alpha") == "Cursor Helios Alpha · cursor-helios-alpha")
        #expect(decoded.menuTitle(of: "grok-4.7") == "Grok 4.7")
        #expect(decoded.resolvedModelID("retired-model") == "grok-4.7")
        #expect(decoded.resolvedModelID("") == "grok-4.7")
        #expect(decoded.resolvedModelID("claude-opus-5-5") == "claude-opus-5-5")

        var updated = decoded
        let empty = try JSONDecoder().decode(InitializeResult.ModelState.self, from: Data(#"{"availableModels":[]}"#.utf8))
        updated.apply(modelState: empty)
        #expect(updated.models.map(\.id) == decoded.models.map(\.id))

        let session = try JSONDecoder().decode(
            NewSessionResult.self,
            from: Data(
                #"{"sessionId":"s","models":"not-a-catalog","configOptions":[{"id":"model","currentValue":"grok-4.7","options":[]}]}"#
                    .utf8))
        #expect(session.sessionId == "s")
        #expect(session.models == nil)
        #expect(session.configOptions?.map(\.id) == ["model"])
    }
}
