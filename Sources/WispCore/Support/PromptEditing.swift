/// Which readline-style deletion a prompt key is, if it is one.
///
/// Command-U is the shortcut people reach for; Control-U is the same unix-line-discard binding.
/// Control-W deletes the previous word (readline's unix-word-rubout). Control-K is left to the text
/// system, which already deletes to the end of the line. Anything else, including a key held with
/// extra modifiers or a key that is still composing an input method, is left alone.
public enum PromptEditing: Sendable {
    public enum Action: Equatable, Sendable {
        /// Delete from the start of the prompt through the caret, including a selection that ends there.
        case toStart
        /// Delete the word before the caret.
        case wordBackward
    }

    public static func deletion(
        key: String, command: Bool, control: Bool, option: Bool, shift: Bool, composing: Bool
    ) -> Action? {
        guard !composing else { return nil }
        switch key.lowercased() {
        case "u" where command && !control && !option && !shift: return .toStart
        case "u" where control && !command && !option && !shift: return .toStart
        case "w" where control && !command && !option && !shift: return .wordBackward
        default: return nil
        }
    }
}
