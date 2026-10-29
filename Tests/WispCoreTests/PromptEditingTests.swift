import Testing

@testable import WispCore

@Suite struct PromptEditingTests {
    @Test func commandUAndControlUDeleteToTheStart() {
        #expect(
            PromptEditing.deletion(key: "u", command: true, control: false, option: false, shift: false, composing: false)
                == .toStart)
        #expect(
            PromptEditing.deletion(key: "U", command: false, control: true, option: false, shift: false, composing: false)
                == .toStart)
    }

    @Test func controlWDeletesThePreviousWord() {
        #expect(
            PromptEditing.deletion(key: "w", command: false, control: true, option: false, shift: false, composing: false)
                == .wordBackward)
    }

    @Test func otherEditingKeysAreLeftAlone() {
        let untouched: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("u", true, false, false, true, false),  // shift
            ("u", true, true, false, false, false),  // command and control
            ("u", false, true, true, false, false),  // option
            ("u", false, false, false, false, false),
            ("k", false, true, false, false, false),  // Control-K stays with the text system
            ("w", true, false, false, false, false),  // Command-W closes the panel
            ("v", true, false, false, false, false),
            ("y", true, false, false, false, false),
            ("\r", false, false, false, false, false),
            ("u", true, false, false, false, true),  // still composing
        ]
        for (key, command, control, option, shift, composing) in untouched {
            #expect(
                PromptEditing.deletion(
                    key: key, command: command, control: control, option: option, shift: shift, composing: composing) == nil)
        }
    }
}
