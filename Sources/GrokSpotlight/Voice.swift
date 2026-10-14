import AVFoundation
import Foundation

/// One dictation: microphone → 16 kHz mono PCM → xAI streaming speech-to-text at `wss://api.x.ai/v1/stt`,
/// the same endpoint and wire format Grok Build's voice mode uses.
///
/// Call the public methods on the main thread. Events arrive on the main queue.
final class VoiceSession {
    enum Event {
        /// The STT socket is open; buffered audio has been flushed.
        case ready
        /// Running preview of the utterance in progress.
        case interim(String)
        /// A finished utterance (`speech_final`), cleanly re-transcribed by the server.
        case utterance(String)
        /// Microphone level, 0...1.
        case level(Float)
        case error(String)
        /// No more events follow.
        case closed
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "grok-spotlight.voice")
    private let engine = AVAudioEngine()
    private var micRunning = false
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var socketReady = false
    private var pendingAudio: [Data] = []
    private var audioDone = false
    private var closed = false
    private var lockedPrefix = ""
    private var lastLevelEmit = Date.distantPast
    private let sampleRate = 16_000.0

    // MARK: Microphone

    static var microphoneAccessUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts capturing immediately; audio is buffered until the socket is ready so the first words are kept.
    func startMicrophone() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw VoiceFailure("No microphone input is available.")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VoiceFailure("Could not set up audio conversion.")
        }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer, converter: converter, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
        micRunning = true
    }

    /// Streams a 16 kHz mono 16-bit WAV file in real time instead of the microphone, then finishes.
    /// Used by `GrokSpotlight ctl voice-file` to test the speech path without a mic.
    func startFile(_ url: URL) throws {
        let wav = try Data(contentsOf: url)
        var offset = 12
        var pcm = Data()
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[offset..<offset + 4], as: UTF8.self)
            let size = Int(wav[offset + 4..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if id == "data" {
                pcm = wav.subdata(in: (offset + 8)..<min(wav.count, offset + 8 + size))
                break
            }
            offset += 8 + size + (size % 2)
        }
        guard !pcm.isEmpty else { throw VoiceFailure("No PCM data in \(url.lastPathComponent).") }
        DispatchQueue.global().async {
            let chunk = 3_200  // 100 ms
            var index = 0
            while index < pcm.count {
                let piece = pcm.subdata(in: index..<min(pcm.count, index + chunk))
                self.queue.async { self.enqueueAudio(piece) }
                index += chunk
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func stopMicrophone() {
        guard micRunning else { return }
        micRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outFormat: AVAudioFormat) {
        emitLevel(buffer)
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let data = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        queue.async { self.enqueueAudio(data) }
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelEmit) > 0.05 else { return }
        lastLevelEmit = now
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(1, max(0, (db + 55) / 40))
        emit(.level(level))
    }

    // MARK: Speech-to-text socket

    func connect(bearer: String, language: String) {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "endpointing", value: "400"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        queue.async {
            guard !self.closed else { return }
            self.urlSession = session
            self.socket = task
            task.resume()
            self.receive()
            self.queue.asyncAfter(deadline: .now() + 10) {
                if !self.socketReady && !self.closed { self.fail("Speech-to-text did not respond.") }
            }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .success(.string(let text)):
                    self.handleServerEvent(text)
                    if !self.closed { self.receive() }
                case .success:
                    self.receive()
                case .failure(let error):
                    self.fail("Speech-to-text connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let type = event["type"] as? String else { return }
        switch type {
        case "transcript.created":
            socketReady = true
            for chunk in pendingAudio { socket?.send(.data(chunk)) { _ in } }
            pendingAudio.removeAll()
            if audioDone { sendAudioDone() }
            emit(.ready)
        case "transcript.partial":
            let raw = (event["text"] as? String) ?? ""
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { return }
            let isFinal = (event["is_final"] as? Bool) ?? false
            let speechFinal = (event["speech_final"] as? Bool) ?? false
            // Same stitching as Grok Build: finalized chunks lock into a running preview, and the
            // committed text only ever comes from `speech_final`, a clean pass over the whole utterance.
            if speechFinal {
                lockedPrefix = ""
                emit(.utterance(piece))
            } else if isFinal {
                lockedPrefix = lockedPrefix.isEmpty ? piece : "\(lockedPrefix) \(piece)"
                emit(.interim(lockedPrefix))
            } else {
                emit(.interim(lockedPrefix.isEmpty ? piece : "\(lockedPrefix) \(piece)"))
            }
        case "transcript.done":
            let final = ((event["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty { emit(.utterance(final)) }
            close(emitClosed: true)
        case "error":
            fail((event["message"] as? String) ?? "Speech-to-text error.")
        default:
            break
        }
    }

    private func enqueueAudio(_ data: Data) {
        guard !closed, !audioDone else { return }
        if socketReady {
            socket?.send(.data(data)) { _ in }
        } else if pendingAudio.count < 1_000 {
            pendingAudio.append(data)
        }
    }

    private func sendAudioDone() {
        socket?.send(.string("{\"type\":\"audio.done\"}")) { _ in }
    }

    // MARK: Lifecycle

    /// Stops the microphone and asks the server for the final transcript; `.closed` follows.
    func finish() {
        stopMicrophone()
        queue.async {
            guard !self.closed, !self.audioDone else { return }
            self.audioDone = true
            // If the socket is still connecting (or auth is still refreshing), `transcript.created`
            // flushes the buffered audio and sends `audio.done` then.
            if self.socketReady { self.sendAudioDone() }
            self.queue.asyncAfter(deadline: .now() + (self.socketReady ? 5 : 15)) {
                if !self.closed { self.close(emitClosed: true) }
            }
        }
    }

    /// Tears everything down without emitting further events.
    func cancel() {
        stopMicrophone()
        queue.async { self.close(emitClosed: false) }
    }

    private func fail(_ message: String) {
        emit(.error(message))
        close(emitClosed: true)
    }

    private func close(emitClosed: Bool) {
        guard !closed else { return }
        closed = true
        pendingAudio.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.finishTasksAndInvalidate()
        socket = nil
        urlSession = nil
        DispatchQueue.main.async { self.stopMicrophone() }
        if emitClosed { emit(.closed) }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}

struct VoiceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
