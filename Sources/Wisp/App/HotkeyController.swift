import Carbon
import WispCore

/// The two global shortcuts, through Carbon's `RegisterEventHotKey`: it needs no Accessibility
/// permission and reports key-up as well as key-down, which hold-to-talk depends on.
@MainActor
final class HotkeyController {
    enum MainKeyEvent {
        /// Key went down. Show the panel right away so it feels instant.
        case pressed
        /// Still held after `holdDelay`: start push-to-talk.
        case holdBegan
        /// Key came up; `held` tells a tap from a hold.
        case released(held: Bool)
    }

    var onMainKey: ((MainKeyEvent) -> Void)?
    var onVoiceKey: (() -> Void)?

    private let holdDelay = Duration.milliseconds(300)
    private var references: [EventHotKeyRef] = []
    private var handlers: [UInt32: (_ pressed: Bool) -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var mainKeyDown = false
    private var holding = false
    private var holdTask: Task<Void, Never>?

    init() {
        installEventHandler()
    }

    /// Registers both shortcuts, replacing any earlier ones. Returns a message naming any that failed.
    func register(mainKey: String, voiceKey: String) -> String? {
        unregisterAll()
        var failed: [String] = []
        if !register(mainKey, handler: { [weak self] in self?.mainKey(pressed: $0) }) { failed.append(mainKey) }
        if !register(voiceKey, handler: { [weak self] pressed in if pressed { self?.onVoiceKey?() } }) { failed.append(voiceKey) }
        guard !failed.isEmpty else { return nil }
        Log.info("hotkeys: could not register \(failed)")
        return "Could not register \(failed.joined(separator: " or ")). The format may be wrong or another app may own it; change it in the config (⌘,)."
    }

    private func mainKey(pressed: Bool) {
        if pressed {
            guard !mainKeyDown else { return }  // key repeat
            mainKeyDown = true
            holding = false
            onMainKey?(.pressed)
            holdTask = Task { [weak self, holdDelay] in
                try? await Task.sleep(for: holdDelay)
                guard let self, !Task.isCancelled, mainKeyDown else { return }
                holding = true
                onMainKey?(.holdBegan)
            }
        } else {
            guard mainKeyDown else { return }
            mainKeyDown = false
            holdTask?.cancel()
            onMainKey?(.released(held: holding))
            holding = false
        }
    }

    // MARK: Carbon

    private func register(_ text: String, handler: @escaping (Bool) -> Void) -> Bool {
        guard let spec = HotkeySpec(text) else { return false }
        let id = UInt32(handlers.count + 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, Self.carbonModifiers(spec.modifiers),
            EventHotKeyID(signature: OSType(0x5749_5350), id: id),  // 'WISP'
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references.append(reference)
        handlers[id] = handler
        return true
    }

    private func unregisterAll() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        handlers.removeAll()
        // A key that was down when its registration went away will never report key-up.
        holdTask?.cancel()
        mainKeyDown = false
        holding = false
    }

    private func installEventHandler() {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            return MainActor.assumeIsolated {
                let controller = Unmanaged<HotkeyController>.fromOpaque(context).takeUnretainedValue()
                guard let handler = controller.handlers[id] else { return OSStatus(eventNotHandledErr) }
                handler(pressed)
                return noErr
            }
        }, events.count, &events, context, &eventHandler)
    }

    private static func carbonModifiers(_ modifiers: HotkeySpec.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}
