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

    func startAgent() async throws -> (GrokAgent, Recorder) {
        let source = try #require(
            Bundle.module.url(forResource: "fake-grok-agent", withExtension: "py", subdirectory: "Fixtures"))
        let executable = FileManager.default.temporaryDirectory.appending(path: "fake-grok-\(UUID().uuidString).py")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let agent = GrokAgent(
            launch: .init(
                executable: executable,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: FileManager.default.temporaryDirectory,
                clientVersion: "test"))
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
        _ = try await agent.prompt("fs", in: session.sessionId)
        #expect(recorder.updates == [.messageChunk("approved:once"), .messageChunk("error:-32601")])
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
            ConfigOption(id: "reasoning_effort", currentValue: "low", values: ["minimal", "low"]),
        ])
        #expect(catalog.efforts(for: "claude") == ["minimal", "low"])
        #expect(catalog.efforts(for: "grok") == ["xhigh", "high", "medium"])
    }

    @Test func effortAdjustsToWhatTheModelAccepts() {
        #expect(catalog.effort("medium", adjustedFor: "grok") == "medium")
        #expect(catalog.effort("low", adjustedFor: "grok") == "high")
        #expect(catalog.effort("minimal", adjustedFor: "claude") == "low")
        #expect(catalog.effort("", adjustedFor: "grok") == "")
    }

    @Test func namesFallBackToIDs() {
        #expect(catalog.name(of: "grok") == "Grok")
        #expect(catalog.name(of: "unknown-model") == "unknown-model")
    }
}
