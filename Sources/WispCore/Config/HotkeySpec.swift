import Foundation

/// A global shortcut parsed from text such as `option+space`, `cmd+shift+k`, or `f5`.
public struct HotkeySpec: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// macOS virtual key code (the `kVK_*` constants).
    public let keyCode: UInt32
    public let modifiers: Modifiers
    let keyName: String

    public init?(_ text: String) {
        var modifiers: Modifiers = []
        var key: (name: String, code: UInt32)?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "shift", "⇧": modifiers.insert(.shift)
            default:
                guard key == nil, let code = Self.keyCodes[part] else { return nil }
                key = (part, code)
            }
        }
        guard let key else { return nil }
        self.keyCode = key.code
        self.modifiers = modifiers
        self.keyName = key.name
    }

    /// Menu-style rendering, for example `⌥Space` or `⌃⇧K`.
    public var display: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + (keyName.count == 1 ? keyName.uppercased() : keyName.capitalized)
    }

    /// Display form of a spec string, or the string itself when it does not parse.
    public static func display(_ text: String) -> String {
        HotkeySpec(text)?.display ?? text
    }

    static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
            ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
            "delete": 51, "escape": 53, "esc": 53,
        ]
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80]
        for (index, code) in functionKeys.enumerated() {
            codes["f\(index + 1)"] = code
        }
        return codes
    }()
}
