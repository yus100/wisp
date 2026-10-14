import Foundation
import Network
import Testing

@testable import WispCore

@Suite struct TranscriptAssemblerTests {
    @Test func stitchesChunksAndCommitsOnSpeechFinal() {
        var transcript = TranscriptAssembler()
        transcript.apply(.ready)
        transcript.apply(.partial(text: "What is the capital of", isFinal: false, speechFinal: false))
        #expect(transcript.text == "What is the capital of")
        transcript.apply(.partial(text: "What is the capital of Australia?", isFinal: true, speechFinal: false))
        transcript.apply(.partial(text: "And how far", isFinal: false, speechFinal: false))
        #expect(transcript.text == "What is the capital of Australia? And how far")
        let finished = transcript.apply(
            .partial(text: "What is the capital of Australia? And how far is it?", isFinal: true, speechFinal: true))
        #expect(finished)
        #expect(transcript.committed == "What is the capital of Australia? And how far is it?")
        #expect(transcript.preview.isEmpty)
        transcript.apply(.done(text: ""))
        #expect(transcript.text == "What is the capital of Australia? And how far is it?")
    }

    @Test func secondUtteranceAppends() {
        var transcript = TranscriptAssembler()
        transcript.apply(.partial(text: "One.", isFinal: true, speechFinal: true))
        transcript.apply(.partial(text: "Two", isFinal: false, speechFinal: false))
        #expect(transcript.text == "One. Two")
        transcript.commitPreview()
        #expect(transcript.committed == "One. Two")
    }

    @Test func doneTextIsKeptUnlessItRepeatsTheLastUtterance() {
        var transcript = TranscriptAssembler()
        transcript.apply(.partial(text: "Hello there.", isFinal: true, speechFinal: true))
        transcript.apply(.done(text: "Hello there."))
        #expect(transcript.text == "Hello there.")
        transcript.apply(.done(text: "One more thing."))
        #expect(transcript.text == "Hello there. One more thing.")
    }

    @Test func blankPartialsAreIgnored() {
        var transcript = TranscriptAssembler()
        let finished = transcript.apply(.partial(text: "  ", isFinal: true, speechFinal: true))
        #expect(!finished)
        #expect(transcript.isEmpty)
    }
}

@Suite struct SpeechEventTests {
    @Test func parsesServerEvents() throws {
        #expect(try SpeechToText.parse(#"{"type":"transcript.created","id":"x"}"#) == .ready)
        #expect(
            try SpeechToText.parse(#"{"type":"transcript.partial","text":"hi","words":[],"is_final":true,"speech_final":false}"#)
                == .partial(text: "hi", isFinal: true, speechFinal: false))
        #expect(try SpeechToText.parse(#"{"type":"transcript.done","text":"","duration":3.2}"#) == .done(text: ""))
        #expect(try SpeechToText.parse(#"{"type":"something.new"}"#) == nil)
        #expect(throws: SpeechToText.Failure.server("bad audio")) {
            try SpeechToText.parse(#"{"type":"error","message":"bad audio"}"#)
        }
    }

    @Test func urlCarriesTheStreamSettings() {
        var options = SpeechToText.Options()
        options.language = "ja"
        let query = options.url.query() ?? ""
        #expect(options.url.absoluteString.hasPrefix("wss://api.x.ai/v1/stt?"))
        for item in ["sample_rate=16000", "encoding=pcm", "interim_results=true", "language=ja", "endpointing=400"] {
            #expect(query.contains(item), "\(item)")
        }
    }
}

@Suite struct SpeechToTextStreamTests {
    func audio(_ chunks: [Data]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    @Test func streamsAudioAndReturnsTheTranscript() async throws {
        let server = try await FakeSpeechServer.start(behavior: .transcribe)
        defer { server.stop() }
        var options = SpeechToText.Options()
        options.endpoint = server.url
        var events: [SpeechToText.Event] = []
        var transcript = TranscriptAssembler()
        let chunk = Data(repeating: 1, count: 3_200)
        for try await event in SpeechToText.transcribe(audio([chunk, chunk, chunk]), bearer: "test-token", options: options) {
            events.append(event)
            transcript.apply(event)
        }
        #expect(events.first == .ready)
        #expect(events.last == .done(text: ""))
        #expect(transcript.text == "hello world")
        #expect(server.received.audioBytes == 9_600)
        #expect(server.received.sawAudioDone)
        #expect(server.received.authorization == "Bearer test-token")
    }

    @Test func serverErrorsFailTheStream() async throws {
        let server = try await FakeSpeechServer.start(behavior: .fail)
        defer { server.stop() }
        var options = SpeechToText.Options()
        options.endpoint = server.url
        await #expect(throws: SpeechToText.Failure.server("invalid audio")) {
            for try await _ in SpeechToText.transcribe(audio([Data(count: 3_200)]), bearer: "t", options: options) {}
        }
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await FakeSpeechServer.start(behavior: .silent)
        defer { server.stop() }
        var options = SpeechToText.Options()
        options.endpoint = server.url
        options.connectTimeout = .milliseconds(300)
        await #expect(throws: SpeechToText.Failure.timedOut("the server to accept the stream")) {
            for try await _ in SpeechToText.transcribe(audio([]), bearer: "t", options: options) {}
        }
    }
}

@Suite struct RecordedAudioTests {
    func wav(rate: UInt32 = 16_000, channels: UInt16 = 1, samples: [Int16]) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples.count * 2))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(samples.count * 2))
        for sample in samples { append(sample) }
        return data
    }

    @Test func extractsPCMFromAWAVFile() throws {
        let pcm = try RecordedAudio.pcm16(fromWAV: wav(samples: [1, -1, 256]))
        #expect(pcm == Data([1, 0, 0xFF, 0xFF, 0, 1]))
    }

    @Test func rejectsOtherFormats() {
        #expect(throws: RecordedAudio.Failure.self) { try RecordedAudio.pcm16(fromWAV: wav(rate: 44_100, samples: [0])) }
        #expect(throws: RecordedAudio.Failure.self) { try RecordedAudio.pcm16(fromWAV: Data("not a wav".utf8)) }
    }

    @Test func streamsInRealTimeChunks() async {
        var chunks: [Int] = []
        for await chunk in RecordedAudio.stream(Data(count: 7_000)) { chunks.append(chunk.count) }
        #expect(chunks == [3_200, 3_200, 600])
    }
}

@Suite struct GrokCredentialsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func authJSON(_ entries: [(key: String, expires: Date)]) -> Data {
        var object: [String: Any] = [:]
        for (index, entry) in entries.enumerated() {
            object["https://auth.x.ai::\(index)"] = [
                "key": entry.key,
                "expires_at": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(entry.expires),
                "refresh_token": "never-read",
            ]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func picksTheLatestTokenOutsideTheMargin() {
        let data = authJSON([
            (key: "old", expires: now.addingTimeInterval(30)), (key: "new", expires: now.addingTimeInterval(600)),
        ])
        #expect(GrokCredentials.freshToken(inAuthJSON: data, now: now, margin: 60) == "new")
    }

    @Test func staleTokensAreRejected() {
        let data = authJSON([(key: "old", expires: now.addingTimeInterval(30))])
        #expect(GrokCredentials.freshToken(inAuthJSON: data, now: now, margin: 60) == nil)
    }

    @Test func parsesGrokTimestamps() throws {
        let data = Data(#"{"https://auth.x.ai::id":{"key":"k","expires_at":"2026-10-14T21:41:39.637488Z"}}"#.utf8)
        let before = try Date("2026-10-14T21:30:00Z", strategy: .iso8601)
        #expect(GrokCredentials.freshToken(inAuthJSON: data, now: before, margin: 60) == "k")
    }

    @Test func apiKeyWins() async throws {
        let bearer = try await GrokCredentials.bearer(
            environment: ["XAI_API_KEY": " xai-123 \n"], grokHome: URL(filePath: "/nonexistent"), grok: nil)
        #expect(bearer == "xai-123")
    }
}

/// A local stand-in for `wss://api.x.ai/v1/stt`, built on Network.framework's WebSocket server.
final class FakeSpeechServer: @unchecked Sendable {
    enum Behavior: Sendable { case transcribe, fail, silent }

    struct Received: Sendable {
        var audioBytes = 0
        var sawAudioDone = false
        var authorization: String?
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-stt")
    private let lock = NSLock()
    private var state = Received()
    private(set) var url = URL(string: "ws://127.0.0.1")!

    var received: Received { lock.withLock { state } }

    static func start(behavior: Behavior) async throws -> FakeSpeechServer {
        let server = FakeSpeechServer()
        try await server.listen(behavior)
        return server
    }

    private func listen(_ behavior: Behavior) async throws {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.setClientRequestHandler(queue) { [self] _, headers in
            lock.withLock { state.authorization = headers.first { $0.name.lowercased() == "authorization" }?.value }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in serve(connection, behavior: behavior) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        url = URL(string: "ws://127.0.0.1:\(port)/v1/stt")!
    }

    func stop() {
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection, behavior: Behavior) {
        connection.start(queue: queue)
        switch behavior {
        case .silent:
            break
        case .fail:
            send(#"{"type":"transcript.created"}"#, on: connection)
            send(#"{"type":"error","message":"invalid audio"}"#, on: connection)
        case .transcribe:
            send(#"{"type":"transcript.created"}"#, on: connection)
            receive(on: connection)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .binary, let content {
                let total = lock.withLock {
                    state.audioBytes += content.count
                    return state.audioBytes
                }
                if total == 3_200 {
                    send(#"{"type":"transcript.partial","text":"hello","is_final":false,"speech_final":false}"#, on: connection)
                }
            } else if metadata?.opcode == .text, let content, String(decoding: content, as: UTF8.self).contains("audio.done") {
                lock.withLock { state.sawAudioDone = true }
                send(#"{"type":"transcript.partial","text":"hello world","is_final":true,"speech_final":true}"#, on: connection)
                send(#"{"type":"transcript.done","text":""}"#, on: connection)
                return
            }
            receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
