import Foundation

/// Decides when a hands-free dictation is over: after `silence` seconds in which the microphone heard
/// no voice and the speech-to-text server produced no new words.
///
/// The server's own end-of-utterance signal (`speech_final`) fires after 400 ms of quiet, and its next
/// transcript only arrives a second or so after speech resumes, so it cannot tell a thinking pause from
/// the end of a dictation. The audio level can, immediately. Words still count as activity, so speech
/// too quiet for the level check never ends a dictation while it is being transcribed.
///
/// Time is measured on the audio clock (samples processed), so behavior is the same for the
/// microphone and for recordings, and tests are deterministic.
public struct EndOfSpeechDetector: Sendable {
    /// Seconds of quiet that end a dictation.
    public let silence: TimeInterval
    /// Seconds of audio processed so far.
    public private(set) var audioTime: TimeInterval = 0
    /// Whether any voice (or any transcribed word) has been noticed yet.
    public private(set) var heardVoice = false
    /// The latest input level, 0...1, for the microphone indicator.
    public private(set) var level: Float = 0

    let sampleRate: Double
    /// Decibels above the noise floor that count as voice.
    static let voiceMargin = 9.0
    /// Below this level nothing counts as voice, however quiet the room.
    static let quietestVoice = -70.0
    /// The noise floor follows quieter input at once and louder input at this rate (dB per second),
    /// so steady background noise is learned within seconds but speech never becomes "the floor".
    static let floorRise = 3.0
    private var noiseFloor = -60.0
    private var lastActivity: TimeInterval?

    public init(silence: TimeInterval, sampleRate: Double = 16_000) {
        self.silence = silence
        self.sampleRate = sampleRate
    }

    /// Feeds a chunk of 16-bit little-endian mono PCM.
    public mutating func process(_ pcm: Data) {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return }
        let duration = Double(sampleCount) / sampleRate
        let decibels = Self.decibels(pcm)
        audioTime += duration
        level = Float(min(1, max(0, (decibels + 55) / 40)))

        if decibels < noiseFloor {
            noiseFloor = decibels
        } else {
            noiseFloor = min(decibels, noiseFloor + Self.floorRise * duration)
        }
        if decibels > max(noiseFloor + Self.voiceMargin, Self.quietestVoice) {
            noteActivity()
        }
    }

    /// New transcribed words: the server heard speech even if the level check did not.
    public mutating func heardWords() {
        noteActivity()
    }

    /// True once there has been activity followed by `silence` seconds without any.
    public var silenceElapsed: Bool {
        guard let lastActivity else { return false }
        return audioTime - lastActivity >= silence
    }

    private mutating func noteActivity() {
        heardVoice = true
        lastActivity = audioTime
    }

    /// Root-mean-square level of 16-bit PCM in dBFS (digital silence reads as -100).
    static func decibels(_ pcm: Data) -> Double {
        var energy = 0.0
        var count = 0
        pcm.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                let value = Double(sample) / 32_768
                energy += value * value
                count += 1
            }
        }
        guard count > 0, energy > 0 else { return -100 }
        return max(-100, 10 * log10(energy / Double(count)))
    }
}
