@preconcurrency import AVFoundation
import Foundation

/// Captures the default input device as 16 kHz mono 16-bit PCM, the format xAI speech-to-text expects.
///
/// Deliberately not main-actor isolated: AVAudioEngine calls the tap on its own audio thread, and a tap
/// closure formed in a main-actor context would trip Swift's isolation checks there.
final class MicrophoneCapture: @unchecked Sendable {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var sink: AsyncStream<Data>.Continuation?

    static var accessUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Starts the microphone. The stream ends when `stop()` is called.
    func start() throws -> AsyncStream<Data> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError("No microphone is available.")
        }
        guard let converter = PCMConverter(from: inputFormat, sampleRate: Self.sampleRate) else {
            throw CaptureError("Could not convert microphone audio.")
        }
        let (stream, sink) = AsyncStream.makeStream(of: Data.self)
        lock.withLock { self.sink = sink }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            if let pcm = converter.convert(buffer) { sink.yield(pcm) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.finish()
            throw error
        }
        return stream
    }

    /// Stops capturing and ends the stream. Safe to call more than once.
    func stop() {
        guard
            let sink = lock.withLock({ () -> AsyncStream<Data>.Continuation? in
                defer { self.sink = nil }
                return self.sink
            })
        else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.finish()
    }

    struct CaptureError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Converts input buffers to 16-bit mono at the target rate. Used only on the audio thread.
private final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat

    init?(from input: AVAudioFormat, sampleRate: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: format)
        else { return nil }
        converter.downmix = true
        self.converter = converter
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
