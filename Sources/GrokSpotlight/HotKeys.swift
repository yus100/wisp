import Carbon
import Foundation

/// System-wide hotkeys through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission
/// and reports both press and release (used for hold-to-talk).
final class HotKeyCenter {
    struct Binding {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private struct Handlers {
        let pressed: () -> Void
        let released: () -> Void
    }

    private var handlers: [UInt32: Handlers] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextId: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let handlers = center.handlers[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                handlers.pressed()
            } else {
                handlers.released()
            }
            return noErr
        }, types.count, &types, context, &eventHandler)
    }

    /// Returns false when the shortcut is malformed or already taken.
    @discardableResult
    func register(_ spec: String, pressed: @escaping () -> Void, released: @escaping () -> Void = {}) -> Bool {
        guard let binding = Self.parse(spec) else { return false }
        let id = nextId
        nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                         EventHotKeyID(signature: OSType(0x4752_4B53), id: id),  // 'GRKS'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = Handlers(pressed: pressed, released: released)
        return true
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    /// Parses shortcuts like "option+space", "cmd+shift+k", "ctrl+opt+return", "f5".
    static func parse(_ spec: String) -> Binding? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default:
                guard keyCode == nil, let code = keyCodes[part] else { return nil }
                keyCode = code
            }
        }
        guard let keyCode else { return nil }
        return Binding(keyCode: keyCode, modifiers: modifiers)
    }

    private static let keyCodes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "`": UInt32(kVK_ANSI_Grave), "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal),
            "[": UInt32(kVK_ANSI_LeftBracket), "]": UInt32(kVK_ANSI_RightBracket), "\\": UInt32(kVK_ANSI_Backslash),
            ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote), ",": UInt32(kVK_ANSI_Comma),
            ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        for (name, code) in letters { map[name] = UInt32(code) }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (index, code) in functionKeys.enumerated() { map["f\(index + 1)"] = UInt32(code) }
        return map
    }()

    /// Human-readable form for menus, e.g. "⌥Space".
    static func display(_ spec: String) -> String {
        var symbols = Set<String>()
        var key = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control", "⌃": symbols.insert("⌃")
            case "opt", "option", "alt", "⌥": symbols.insert("⌥")
            case "shift", "⇧": symbols.insert("⇧")
            case "cmd", "command", "⌘": symbols.insert("⌘")
            default: key = part.count == 1 ? part.uppercased() : part.capitalized
            }
        }
        return ["⌃", "⌥", "⇧", "⌘"].filter(symbols.contains).joined() + key
    }
}
