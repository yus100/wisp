import Foundation

/// Streaming speech-to-text over `wss://api.x.ai/v1/stt`, the endpoint and wire format Grok Build's
/// voice mode uses: binary frames of 16-bit little-endian mono PCM in, JSON transcript events out.
public enum SpeechToText {
    public struct Options: Sendable {
        public var endpoint = URL(string: "wss://api.x.ai/v1/stt")!
        public var language = "en"
        public var sampleRate = 16_000
        /// Silence (ms) after which the server marks an utterance `speech_final`.
        public var endpointingMilliseconds = 400
        public var connectTimeout = Duration.seconds(10)
        /// How long to wait for `transcript.done` after the audio ends.
        public var finalTimeout = Duration.seconds(6)

        public init() {}

        var url: URL {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "sample_rate", value: String(sampleRate)),
                URLQueryItem(name: "encoding", value: "pcm"),
                URLQueryItem(name: "interim_results", value: "true"),
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "endpointing", value: String(endpointingMilliseconds)),
            ]
            return components.url!
        }
    }

    public enum Event: Equatable, Sendable {
        /// The server accepted the stream; buffered audio is flowing.
        case ready
        /// Interim text for the current chunk. `isFinal` locks the chunk; `speechFinal` ends the utterance
        /// and carries a clean re-transcription of all of it.
        case partial(text: String, isFinal: Bool, speechFinal: Bool)
        /// The server finished after `audio.done`. The text is usually empty because `speechFinal` already delivered it.
        case done(text: String)
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case server(String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .server(let message): "Speech-to-text error: \(message)"
            case .timedOut(let what): "Speech-to-text timed out waiting for \(what)."
            }
        }
    }

    /// Streams `audio` until it finishes, then yields events until the server's `transcript.done`.
    ///
    /// Audio produced before the connection is ready waits in `audio`'s buffer, so nothing said while
    /// connecting is lost. Cancelling the consuming task closes the socket.
    public static func transcribe(
        _ audio: AsyncStream<Data>, bearer: String, options: Options = Options()
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var request = URLRequest(url: options.url)
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
                let session = URLSession(configuration: .ephemeral)
                let socket = session.webSocketTask(with: request)
                defer {
                    socket.cancel(with: .normalClosure, reason: nil)
                    session.finishTasksAndInvalidate()
                }
                socket.resume()
                do {
                    try await withTaskCancellationHandler {
                        try await run(socket: socket, audio: audio, options: options) { continuation.yield($0) }
                    } onCancel: {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Phase: Sendable {
        case audioSent
        case transcriptDone
    }

    private static func run(
        socket: URLSessionWebSocketTask, audio: AsyncStream<Data>, options: Options,
        emit: @escaping @Sendable (Event) -> Void
    ) async throws {
        try await withDeadline(options.connectTimeout, "the server to accept the stream") {
            while true {
                if case .ready? = try await nextEvent(socket) { return }
            }
        }
        emit(.ready)

        try await withThrowingTaskGroup(of: Phase.self) { group in
            group.addTask {
                for await chunk in audio { try await socket.send(.data(chunk)) }
                try await socket.send(.string(#"{"type":"audio.done"}"#))
                return .audioSent
            }
            group.addTask {
                while true {
                    guard let event = try await nextEvent(socket) else { continue }
                    emit(event)
                    if case .done = event { return .transcriptDone }
                }
            }
            while let phase = try await group.next() {
                switch phase {
                case .transcriptDone:
                    group.cancelAll()
                    return
                case .audioSent:
                    group.addTask {
                        try await Task.sleep(for: options.finalTimeout)
                        throw Failure.timedOut("the final transcript")
                    }
                }
            }
        }
    }

    /// `receive()` ignores task cancellation, so a cancelled reader (timeout, stop) closes the socket to wake it.
    private static func nextEvent(_ socket: URLSessionWebSocketTask) async throws -> Event? {
        let message = try await withTaskCancellationHandler {
            try await socket.receive()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        guard case .string(let text) = message else { return nil }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Event? {
        struct Message: Decodable {
            let type: String
            let text: String?
            let is_final: Bool?
            let speech_final: Bool?
            let message: String?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return nil }
        switch message.type {
        case "transcript.created":
            return .ready
        case "transcript.partial":
            return .partial(text: message.text ?? "", isFinal: message.is_final ?? false, speechFinal: message.speech_final ?? false)
        case "transcript.done":
            return .done(text: message.text ?? "")
        case "error":
            throw Failure.server(message.message ?? "unknown error")
        default:
            return nil
        }
    }
}

/// Runs `operation`, failing with `SpeechToText.Failure.timedOut` if it takes longer than `limit`.
func withDeadline<T: Sendable>(
    _ limit: Duration, _ what: String, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw SpeechToText.Failure.timedOut(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
