import Foundation

/// Turns speech-to-text events into the text shown while dictating and the text that gets sent.
///
/// Same stitching as Grok Build: chunks marked `isFinal` lock into a running preview so a long
/// utterance keeps growing, and committed text only ever comes from `speechFinal`, which the
/// server sends as a clean pass over the whole utterance.
public struct TranscriptAssembler: Equatable, Sendable {
    /// Finished utterances.
    public private(set) var committed = ""
    /// The utterance in progress.
    public private(set) var preview = ""
    private var lockedPrefix = ""
    private var lastUtterance = ""

    public init() {}

    public var text: String { Self.join(committed, preview) }
    public var isEmpty: Bool { committed.isEmpty && preview.isEmpty }

    /// Applies an event and returns true when it finished an utterance.
    @discardableResult
    public mutating func apply(_ event: SpeechToText.Event) -> Bool {
        switch event {
        case .ready:
            return false
        case .partial(let raw, let isFinal, let speechFinal):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            if speechFinal {
                commit(text)
                return true
            }
            if isFinal {
                lockedPrefix = Self.join(lockedPrefix, text)
                preview = lockedPrefix
            } else {
                preview = Self.join(lockedPrefix, text)
            }
            return false
        case .done(let raw):
            // Normally empty because `speechFinal` already delivered everything. Grok Build commits any
            // text it does carry; skip it only when it repeats the utterance just committed.
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != lastUtterance else { return false }
            commit(text)
            return true
        }
    }

    /// Keeps a preview the server never finalized (for example, the stream was cut short).
    public mutating func commitPreview() {
        guard !preview.isEmpty else { return }
        commit(preview)
    }

    private mutating func commit(_ text: String) {
        committed = Self.join(committed, text)
        lastUtterance = text
        preview = ""
        lockedPrefix = ""
    }

    static func join(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
