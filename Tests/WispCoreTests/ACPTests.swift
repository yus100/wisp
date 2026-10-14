import Foundation
import Testing

@testable import WispCore

@Suite struct LineFramerTests {
    @Test func reassemblesLinesAcrossChunks() {
        var framer = LineFramer()
        #expect(framer.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(framer.append(Data("1}\n{\"b\":2}\r\n\n{\"c\"".utf8)) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        #expect(framer.append(Data(":3}\n".utf8)) == [Data("{\"c\":3}".utf8)])
    }

    @Test func doesNotSplitOnUnicodeLineSeparators() {
        var framer = LineFramer()
        let line = "{\"text\":\"one\u{2028}two\u{2029}three\"}"
        #expect(framer.append(Data((line + "\n").utf8)) == [Data(line.utf8)])
    }
}

/// Captures what an `ACPConnection` sends.
private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []

    func send(_ data: Data) { lock.withLock { lines.append(data) } }

    var sent: [[String: Any]] {
        lock.withLock { lines }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

@Suite struct ACPConnectionTests {
    @Test func requestEncodesAndDecodesTheReply() async throws {
        let outbox = Outbox()
        let connection = ACPConnection { outbox.send($0) }
        let reply = Task {
            try await connection.request("session/close", params: SessionParams(sessionId: "s1"), as: EmptyResult.self)
        }
        try await waitFor { outbox.sent.count == 1 }
        let sent = try #require(outbox.sent.first)
        #expect(sent["method"] as? String == "session/close")
        #expect((sent["params"] as? [String: Any])?["sessionId"] as? String == "s1")
        #expect(sent["id"] as? Int == 1)
        #expect(await connection.receive(Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)) == nil)
        _ = try await reply.value
    }

    @Test func errorRepliesThrowWithDetail() async throws {
        let outbox = Outbox()
        let connection = ACPConnection { outbox.send($0) }
        let reply = Task {
            try await connection.request("session/new", params: SessionParams(sessionId: "x"), as: NewSessionResult.self)
        }
        try await waitFor { outbox.sent.count == 1 }
        _ = await connection.receive(
            Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"bad cwd"}}"#.utf8))
        await #expect(throws: ACPError.rpc(code: -32602, message: "Invalid params: bad cwd")) { try await reply.value }
    }

    @Test func notificationsAndAgentRequestsAreReturned() async {
        let connection = ACPConnection { _ in }
        let notification = await connection.receive(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#.utf8))
        guard case .notification("session/update", _)? = notification else {
            Issue.record("expected a notification, got \(String(describing: notification))")
            return
        }
        let request = await connection.receive(
            Data(#"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{}}"#.utf8))
        guard case .request(.string("p1"), "session/request_permission", _)? = request else {
            Issue.record("expected a request, got \(String(describing: request))")
            return
        }
    }

    @Test func cancellingTheCallerAbandonsTheRequest() async throws {
        let outbox = Outbox()
        let connection = ACPConnection { outbox.send($0) }
        let start = ContinuousClock.now
        await #expect(throws: TimedOut.self) {
            try await withDeadline(.milliseconds(200), "a reply") {
                try await connection.request("initialize", params: SessionParams(sessionId: "s"), as: EmptyResult.self)
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
        // A reply that arrives after the caller gave up is ignored.
        #expect(await connection.receive(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == nil)
    }

    @Test func closeFailsPendingAndLaterRequests() async throws {
        let outbox = Outbox()
        let connection = ACPConnection { outbox.send($0) }
        let reply = Task {
            try await connection.request("session/prompt", params: SessionParams(sessionId: "s"), as: PromptResult.self)
        }
        try await waitFor { outbox.sent.count == 1 }
        await connection.close()
        await #expect(throws: ACPError.disconnected) { try await reply.value }
        await #expect(throws: ACPError.disconnected) {
            try await connection.request("session/close", params: SessionParams(sessionId: "s"), as: EmptyResult.self)
        }
    }
}

@Suite struct SessionUpdateDecodingTests {
    func decode(_ json: String) throws -> SessionNotification {
        try JSONDecoder().decode(SessionNotification.self, from: Data(json.utf8))
    }

    @Test func messageChunk() throws {
        let note = try decode(
            #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}"#)
        #expect(note.sessionId == "s")
        #expect(note.update == .messageChunk("Hi"))
    }

    @Test func toolCallKeepsTheUsefulArguments() throws {
        let note = try decode(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call","toolCallId":"t","title":"run_terminal_command",
             "rawInput":{"command":"ls","timeout":30,"nested":{"x":1}},"status":"pending"}}
            """)
        #expect(
            note.update
                == .toolCall(ToolCall(id: "t", title: "run_terminal_command", status: "pending", input: ToolInput(command: "ls")))
        )
    }

    @Test func retryStatesInBothKeyStyles() throws {
        let retrying = try decode(
            #"{"sessionId":"s","update":{"sessionUpdate":"retry_state","type":"retrying","attempt":2,"max_retries":5,"reason":"502"}}"#
        )
        #expect(retrying.update == .retry(.retrying(attempt: 2, maxRetries: 5)))
        let failed = try decode(
            #"{"sessionId":"s","update":{"sessionUpdate":"retry_state","type":"failed","errorType":"auth","message":"bad token"}}"#
        )
        #expect(failed.update == .retry(.failed(message: "bad token", isAuthError: true)))
    }

    @Test func unknownKindsAndNonTextContentDecode() throws {
        #expect(try decode(#"{"sessionId":"s","update":{"sessionUpdate":"plan","entries":[]}}"#).update == .other("plan"))
        let image = try decode(
            #"{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"…"}}}"#)
        #expect(image.update == .messageChunk(""))
    }

    @Test func configOptionsTolerateNonStringValues() throws {
        let options = try JSONDecoder().decode(
            [ConfigOption].self,
            from: Data(
                #"""
                [{"id":"model","currentValue":"m","options":[{"value":"m","name":"M"}]},
                 {"id":"flag","currentValue":true,"options":[{"value":false}]}]
                """#.utf8))
        #expect(
            options == [
                ConfigOption(id: "model", currentValue: "m", values: ["m"]),
                ConfigOption(id: "flag", currentValue: nil, values: []),
            ])
    }
}

/// Polls until `condition` holds, failing after two seconds.
func waitFor(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
