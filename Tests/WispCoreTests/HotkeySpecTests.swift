import Carbon
import Testing

@testable import WispCore

@Suite struct HotkeySpecTests {
    @Test func parsesModifiersAndKey() throws {
        let spec = try #require(HotkeySpec("option+shift+space"))
        #expect(spec.keyCode == UInt32(kVK_Space))
        #expect(spec.modifiers == [.option, .shift])
        #expect(spec.display == "⌥⇧Space")
    }

    @Test func acceptsAliasesAndSymbols() throws {
        #expect(HotkeySpec("cmd+opt+k")?.modifiers == [.command, .option])
        #expect(HotkeySpec("⌃+⌘+ return")?.keyCode == UInt32(kVK_Return))
        #expect(HotkeySpec("F5")?.display == "F5")
    }

    @Test func rejectsUnknownOrMissingKeys() {
        #expect(HotkeySpec("option+bogus") == nil)
        #expect(HotkeySpec("option+shift") == nil)
        #expect(HotkeySpec("a+b") == nil)
        #expect(HotkeySpec.display("option+bogus") == "option+bogus")
    }

    @Test func keyCodesMatchCarbon() {
        let expected: [String: Int] = [
            "a": kVK_ANSI_A, "k": kVK_ANSI_K, "m": kVK_ANSI_M, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "5": kVK_ANSI_5,
            "9": kVK_ANSI_9, "`": kVK_ANSI_Grave, "/": kVK_ANSI_Slash, "space": kVK_Space, "return": kVK_Return,
            "tab": kVK_Tab, "escape": kVK_Escape, "f1": kVK_F1, "f12": kVK_F12, "f19": kVK_F19,
        ]
        for (name, code) in expected {
            #expect(HotkeySpec.keyCodes[name] == UInt32(code), "\(name)")
        }
    }
}
