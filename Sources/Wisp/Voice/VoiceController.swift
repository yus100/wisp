import Foundation
import WispCore

/// One dictation at a time: microphone (or a WAV file) → xAI speech-to-text → transcript.
///
/// Audio passes through a forwarding stage on its way to speech-to-text, where it drives the level
/// meter and the end-of-speech detector. Finishing ends that stage, so the microphone and recordings
/// stop the same way. Every step checks the dictation's generation token, so a stale task (from a
/// cancelled or superseded dictation) can never change the state of a newer one.
@MainActor
final class VoiceController: ObservableObject {
    enum Mode {
        /// Hold the hotkey; release to send.
        case pushToTalk
        /// Sends after a pause, or when stopped.
        case handsFree
    }

    enum State: Equatable {
        case idle
        /// Waiting for microphone permission or the first audio.
        case starting
        case listening
        /// Audio ended; waiting for the final transcript.
        case finishing
    }

    @Published private(set) var state = State.idle
    @Published private(set) var level: Float = 0
    @Published private(set) var mode = Mode.handsFree

    var isActive: Bool { state != .idle }

    /// The transcript so far, on every change.
    var onTranscript: ((String) -> Void)?
    /// The dictation ended: final text, and whether it should be sent.
    var onFinish: ((_ text: String, _ send: Bool) -> Void)?
    /// Something to tell the user (permission prompt, errors).
    var onNotice: ((String) -> Void)?
    /// Supplies the speech-to-text bearer token.
    var credentials: (() async throws -> String)?

    var language = "en"
    /// Hands-free dictation sends once the speaker has been quiet this many seconds; 0 waits for the
    /// hotkey or Return.
    var pauseSeconds = 2.5

    private var generation: UUID?
    private var microphone: MicrophoneCapture?
    private var detector = EndOfSpeechDetector(silence: 2.5)
    private var audioSink: AsyncStream<Data>.Continuation?
    private var sendWhenDone = false
    private var stopRequested = false
    /// Any transcribed text so far in this dictation.
    private var hasText = false
    private var task: Task<Void, Never>?
    private var forwarder: Task<Void, Never>?
    private var noSpeechTask: Task<Void, Never>?

    /// Starts listening. `recording` (WAV bytes) plays instead of the microphone and sends when it ends.
    func start(_ mode: Mode, recording: Data? = nil) {
        guard state == .idle else { return }
        let id = UUID()
        generation = id
        self.mode = mode
        state = .starting
        detector = EndOfSpeechDetector(silence: pauseSeconds)
        sendWhenDone = recording != nil
        stopRequested = false
        hasText = false
        task = Task { await run(id, recording: recording) }
    }

    /// Stops listening; the transcript is delivered (and sent, if `send`) once the server finalizes it.
    func finish(send: Bool) {
        guard state != .idle else { return }
        sendWhenDone = send
        stopRequested = true
        noSpeechTask?.cancel()
        if state == .listening { state = .finishing }
        // Ending the outgoing audio makes the speech-to-text client send `audio.done`.
        stopAudio()
    }

    /// Stops immediately and drops anything still in flight. Text already transcribed stays where it is.
    func cancel() {
        guard state != .idle else { return }
        generation = nil
        task?.cancel()
        reset()
    }

    // MARK: Private

    /// One dictation. Its transcript is local, and every step checks `generation`: a cancelled stream
    /// ends its loop without throwing, so the checks are what keep stale text out of the input.
    private func run(_ id: UUID, recording: Data?) async {
        var transcript = TranscriptAssembler()
        do {
            guard let source = try await openAudio(id, recording: recording), generation == id else {
                return complete(id, text: "", error: nil)
            }
            let audio = forward(source, id)
            state = stopRequested ? .finishing : .listening

            guard let credentials else { throw GrokCredentials.Failure.notSignedIn }
            let bearer = try await credentials()
            var options = SpeechToText.Options()
            options.language = language
            for try await event in SpeechToText.transcribe(audio, bearer: bearer, options: options) {
                guard generation == id else { return }
                handle(event, transcript: &transcript, id)
            }
            guard generation == id else { return }
            transcript.commitPreview()
            onTranscript?(transcript.text)
            complete(id, text: transcript.text, error: nil)
        } catch {
            complete(id, text: transcript.text, error: error is CancellationError ? nil : error)
        }
    }

    /// The audio source, or nil when the user stopped before the microphone ever opened.
    private func openAudio(_ id: UUID, recording: Data?) async throws -> AsyncStream<Data>? {
        if let recording {
            return RecordedAudio.stream(try RecordedAudio.pcm16(fromWAV: recording))
        }
        if MicrophoneCapture.accessUndecided {
            onNotice?("Allow microphone access in the macOS prompt to use voice.")
        }
        guard await MicrophoneCapture.requestAccess() else {
            throw VoiceError("Microphone access is off. Turn on Wisp in System Settings › Privacy & Security › Microphone.")
        }
        guard generation == id, !stopRequested else { return nil }
        let microphone = MicrophoneCapture()
        let stream = try microphone.start()
        self.microphone = microphone
        return stream
    }

    /// Passes audio through to speech-to-text, measuring it on the way: the level for the mic indicator,
    /// and, in hands-free mode, the pause that ends the dictation.
    private func forward(_ source: AsyncStream<Data>, _ id: UUID) -> AsyncStream<Data> {
        let (outgoing, sink) = AsyncStream.makeStream(of: Data.self)
        audioSink = sink
        forwarder = Task { [weak self] in
            for await chunk in source {
                guard let self, generation == id, !Task.isCancelled else { break }
                sink.yield(chunk)
                detector.process(chunk)
                level = detector.level
                if mode == .handsFree, pauseSeconds > 0, hasText, !stopRequested, detector.silenceElapsed {
                    finish(send: true)
                }
            }
            sink.finish()
        }
        return outgoing
    }

    private func handle(_ event: SpeechToText.Event, transcript: inout TranscriptAssembler, _ id: UUID) {
        // Time "no speech" from when the stream is up, not from the token refresh or connect before it.
        if case .ready = event { armNoSpeechWatchdog(id) }
        transcript.apply(event)
        hasText = hasText || !transcript.isEmpty
        // Live (non-final) text arrives only while someone is talking, so it counts as activity;
        // the finalized repeats that follow a pause do not.
        if case .partial(let text, isFinal: false, _) = event, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            detector.heardWords()
        }
        onTranscript?(transcript.text)
    }

    private func armNoSpeechWatchdog(_ id: UUID) {
        noSpeechTask?.cancel()
        noSpeechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, generation == id, !hasText else { return }
            let heardSound = detector.heardVoice
            finish(send: false)
            onNotice?(
                heardSound
                    ? "Wisp hears sound but no words are coming back. Try speaking closer to the microphone."
                    : "No speech detected. Check the input device in System Settings › Sound.")
        }
    }

    private func stopAudio() {
        microphone?.stop()
        audioSink?.finish()
        forwarder?.cancel()
    }

    private func complete(_ id: UUID, text: String, error: Error?) {
        guard generation == id else { return }
        generation = nil
        let send = sendWhenDone && !text.isEmpty
        reset()
        if let error { onNotice?(error.localizedDescription) }
        onFinish?(text, send && error == nil)
    }

    private func reset() {
        stopAudio()
        microphone = nil
        audioSink = nil
        forwarder = nil
        noSpeechTask?.cancel()
        state = .idle
        level = 0
    }

    struct VoiceError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
