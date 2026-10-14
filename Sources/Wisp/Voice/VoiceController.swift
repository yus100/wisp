import Foundation
import WispCore

/// One dictation at a time: microphone (or a WAV file) → xAI speech-to-text → transcript.
///
/// Every step of a dictation checks its generation token, so a stale task (from a cancelled or
/// superseded dictation) can never change the state of a newer one.
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
        /// Microphone off; waiting for the final transcript.
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
    var silenceSeconds = 1.2

    private var generation: UUID?
    private var microphone: MicrophoneCapture?
    private var sendWhenDone = false
    private var stopRequested = false
    private var heardSpeech = false
    private var task: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var noSpeechTask: Task<Void, Never>?

    /// Starts listening. `recording` (WAV bytes) plays instead of the microphone and sends when it ends.
    func start(_ mode: Mode, recording: Data? = nil) {
        guard state == .idle else { return }
        let id = UUID()
        generation = id
        self.mode = mode
        state = .starting
        sendWhenDone = recording != nil
        stopRequested = false
        heardSpeech = false
        task = Task { await run(id, recording: recording) }
    }

    /// Stops listening; the transcript is delivered (and sent, if `send`) once the server finalizes it.
    func finish(send: Bool) {
        guard state != .idle else { return }
        sendWhenDone = send
        stopRequested = true
        silenceTask?.cancel()
        noSpeechTask?.cancel()
        if state == .listening { state = .finishing }
        // Ending the audio stream makes the speech-to-text client send `audio.done`.
        microphone?.stop()
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
            let audio = try await openAudio(id, recording: recording)
            guard let audio, generation == id else { return complete(id, text: "", error: nil) }
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
        let stream = try microphone.start { [weak self] level in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.level = level
            }
        }
        self.microphone = microphone
        return stream
    }

    private func handle(_ event: SpeechToText.Event, transcript: inout TranscriptAssembler, _ id: UUID) {
        // Time "no speech" from when the stream is up, not from the token refresh or connect before it.
        if case .ready = event { armNoSpeechWatchdog(id) }
        let finishedUtterance = transcript.apply(event)
        if case .partial(let text, _, _) = event, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            heardSpeech = true
            silenceTask?.cancel()
        }
        onTranscript?(transcript.text)
        if finishedUtterance, mode == .handsFree, silenceSeconds > 0, !stopRequested {
            silenceTask = Task { [weak self, silenceSeconds] in
                try? await Task.sleep(for: .seconds(silenceSeconds))
                guard let self, !Task.isCancelled, generation == id else { return }
                finish(send: true)
            }
        }
    }

    private func armNoSpeechWatchdog(_ id: UUID) {
        noSpeechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, generation == id, !heardSpeech else { return }
            finish(send: false)
            onNotice?("No speech detected. Check the input device in System Settings › Sound.")
        }
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
        microphone?.stop()
        microphone = nil
        silenceTask?.cancel()
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
