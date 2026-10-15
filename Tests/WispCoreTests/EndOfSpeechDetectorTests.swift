import Foundation
import Testing

@testable import WispCore

/// Synthetic microphone input: 100 ms chunks of 16 kHz PCM at a given RMS level.
private struct Signal {
    static let chunkSeconds = 0.1

    /// A tone whose RMS is `decibels` dBFS ("speech"), or digital silence for nil.
    static func chunk(_ decibels: Double?) -> Data {
        let count = Int(16_000 * chunkSeconds)
        guard let decibels else { return Data(count: count * 2) }
        let amplitude = pow(10, decibels / 20) * 2.0.squareRoot() * 32_767
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let sample = Int16(clamping: Int((amplitude * sin(Double(index) * 2 * .pi * 220 / 16_000)).rounded()))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Feeds `seconds` of input at `decibels` and returns whether silence had elapsed at any point.
    @discardableResult
    static func feed(_ detector: inout EndOfSpeechDetector, _ decibels: Double?, for seconds: Double) -> Bool {
        var elapsed = false
        for _ in 0..<Int((seconds / chunkSeconds).rounded()) {
            detector.process(chunk(decibels))
            elapsed = elapsed || detector.silenceElapsed
        }
        return elapsed
    }
}

@Suite struct EndOfSpeechDetectorTests {
    @Test func measuresLevelsInDecibels() {
        #expect(abs(EndOfSpeechDetector.decibels(Signal.chunk(-30)) - -30) < 0.5)
        #expect(EndOfSpeechDetector.decibels(Signal.chunk(nil)) == -100)
    }

    @Test func nothingEndsBeforeAnyVoice() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        #expect(!Signal.feed(&detector, nil, for: 10))
        #expect(!detector.heardVoice)
    }

    @Test func endsAfterTheConfiguredSilence() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        Signal.feed(&detector, -30, for: 3)
        #expect(detector.heardVoice)
        #expect(!Signal.feed(&detector, nil, for: 2.3))
        #expect(Signal.feed(&detector, nil, for: 0.3))
    }

    /// The bug in issue #1: a two-second thinking pause ended the dictation.
    @Test func thinkingPausesDoNotEndADictation() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        for _ in 0..<5 {
            #expect(!Signal.feed(&detector, -30, for: 3))
            #expect(!Signal.feed(&detector, nil, for: 2))
        }
        #expect(Signal.feed(&detector, nil, for: 1))
    }

    @Test func wordsCountWhenSpeechIsTooQuietToDetect() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        // -75 dBFS is below the quietest level that counts as voice.
        for _ in 0..<6 {
            #expect(!Signal.feed(&detector, -75, for: 1))
            detector.heardWords()
        }
        #expect(!Signal.feed(&detector, -75, for: 2))
        #expect(Signal.feed(&detector, -75, for: 1))
    }

    @Test func steadyBackgroundNoiseIsLearnedAndIgnored() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        // A fan at -45 dBFS: heard as activity until the floor catches up, then ignored.
        Signal.feed(&detector, -45, for: 8)
        #expect(Signal.feed(&detector, -45, for: 3))
        // Speech over the fan is still voice.
        Signal.feed(&detector, -25, for: 1)
        #expect(!detector.silenceElapsed)
        #expect(!Signal.feed(&detector, -45, for: 2))
        #expect(Signal.feed(&detector, -45, for: 1))
    }

    @Test func speechFromTheFirstChunkIsVoice() {
        var detector = EndOfSpeechDetector(silence: 2.5)
        detector.process(Signal.chunk(-40))
        #expect(detector.heardVoice)
        #expect(detector.level > 0)
    }
}
