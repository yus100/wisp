import Foundation

/// Plays a recording into the speech-to-text stream in real time, in place of the microphone.
/// `Wisp ctl voice-file` uses it to exercise the whole voice path without anyone speaking.
public enum RecordedAudio {
    public enum Failure: LocalizedError, Equatable {
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let reason): "Unsupported WAV file: \(reason). Use 16 kHz mono 16-bit PCM."
            }
        }
    }

    /// The PCM samples of a 16 kHz mono 16-bit WAV file, for example from
    /// `say -o question.wav --data-format=LEI16@16000 "..."`.
    public static func pcm16(fromWAV wav: Data) throws -> Data {
        guard wav.count >= 12, wav.prefix(4) == Data("RIFF".utf8), wav[8..<12] == Data("WAVE".utf8) else {
            throw Failure.unsupported("not a RIFF/WAVE file")
        }
        var offset = 12
        var formatOK = false
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[offset..<offset + 4], as: UTF8.self)
            let size = Int(wav.littleEndianUInt32(at: offset + 4))
            let body = offset + 8
            guard body + size <= wav.count || id == "data" else { break }
            if id == "fmt ", size >= 16 {
                let format = wav.littleEndianUInt16(at: body)
                let channels = wav.littleEndianUInt16(at: body + 2)
                let rate = wav.littleEndianUInt32(at: body + 4)
                let bits = wav.littleEndianUInt16(at: body + 14)
                guard format == 1, channels == 1, rate == 16_000, bits == 16 else {
                    throw Failure.unsupported("format \(format), \(channels) channel(s), \(rate) Hz, \(bits)-bit")
                }
                formatOK = true
            } else if id == "data" {
                guard formatOK else { throw Failure.unsupported("data before fmt chunk") }
                return wav.subdata(in: body..<min(wav.count, body + size))
            }
            offset = body + size + (size % 2)
        }
        throw Failure.unsupported("no data chunk")
    }

    /// Yields `pcm` in 100 ms chunks at real-time pace, then finishes.
    public static func stream(_ pcm: Data, sampleRate: Int = 16_000) -> AsyncStream<Data> {
        let chunkBytes = sampleRate / 10 * 2
        return AsyncStream { continuation in
            let task = Task {
                var index = pcm.startIndex
                while index < pcm.endIndex, !Task.isCancelled {
                    let end = min(pcm.endIndex, index + chunkBytes)
                    continuation.yield(pcm.subdata(in: index..<end))
                    index = end
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Data {
    fileprivate func littleEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
