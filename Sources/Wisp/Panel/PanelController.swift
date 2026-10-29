import AppKit
import SwiftUI
import WispCore

/// A borderless floating panel that takes keyboard focus without activating Wisp, so the app you were
/// in stays frontmost, as with Spotlight.
final class WispPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Layout values the SwiftUI content needs from the window side.
@MainActor
final class PanelLayout: ObservableObject {
    @Published var maxConversationHeight: CGFloat = 480
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 720
    static let cornerRadius: CGFloat = 16

    let model: AppModel
    let panel: WispPanel
    let effectView = NSVisualEffectView()
    private(set) var hostingView: NSHostingView<PanelView>!
    let layout = PanelLayout()
    private var keyMonitor: Any?
    private var topEdge: CGFloat = 0
    private var measuredHeight: CGFloat = 56
    /// The height with nothing but the input row, for opening right after an idle reset.
    private var emptyHeight: CGFloat = 56
    private var pendingHeight: CGFloat?
    /// The open file picker; it takes focus without dismissing the panel.
    private(set) var picker: NSOpenPanel?
    /// The user moved to another app with the picker open, so it was cancelled.
    private var pickerAbandoned = false
    private var mouseUpMonitor: Any?
    /// The app most recently in front other than Wisp: what "Attach Window" captures, and where focus
    /// goes back to when Wisp itself was active.
    private var previousApp = NSWorkspace.shared.frontmostApplication
    private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = WispPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 56),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let root = PanelView(
            model: model, voice: model.voice, layout: layout,
            onHeightChange: { [weak self] in self?.resize(to: $0) },
            onModelMenu: { [weak self] in self?.showModelMenu() },
            onAttachMenu: { [weak self] in self?.showAttachMenu() },
            onDropFiles: { [weak self] in self?.attachDropped($0) })
        hostingView = NSHostingView(rootView: root)
        // The window height follows the measured SwiftUI height (see `resize`). Constraints derived
        // from the hosting view's own size would stop the window from ever shrinking.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        panel.contentView = effectView
        // The hand-off is bringing Ghostty forward; leave focus to it.
        model.onRequestHide = { [weak self] in self?.hide(returnFocus: false) }
        if previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier { previousApp = nil }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            MainActor.assumeIsolated { self?.otherAppActivated(app) }
        }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Show and hide

    /// Opens on the screen with the mouse, a fifth of the way down. When already open, takes focus.
    func show() {
        if !panel.isVisible {
            model.contextApp = previousApp
            model.panelWillOpen()
            // An idle reset may just have cleared the conversation; open at the empty height, not the old one.
            if model.conversation.isEmpty && model.notice == nil { measuredHeight = emptyHeight }
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                layout.maxConversationHeight = max(200, frame.height * 0.62 - 120)
                topEdge = frame.maxY - frame.height * 0.2
                panel.setFrame(
                    NSRect(
                        x: frame.midX - Self.width / 2, y: topEdge - measuredHeight, width: Self.width, height: measuredHeight),
                    display: false)
            }
        }
        stopWaitingForMouseUp()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        model.focusInput()
    }

    /// `returnFocus`: when Wisp itself is the frontmost app (after the file picker or a notification
    /// click), hand focus back to the previous app. Not wanted when another app is already taking over.
    func hide(returnFocus: Bool = true) {
        if model.voice.isActive, model.voice.mode == .pushToTalk { model.voice.cancel() }
        // A notice belongs to the moment it was seen in; closing the panel dismisses it.
        if panel.isVisible { model.notice = nil }
        panel.orderOut(nil)
        removeKeyMonitor()
        stopWaitingForMouseUp()
        // NSApp.isActive can read true while only the non-activating panel is key; ask the workspace.
        let wispInFront = NSWorkspace.shared.frontmostApplication == NSRunningApplication.current
        if returnFocus, wispInFront, let app = previousApp, !app.isTerminated { app.activate() }
    }

    private func otherAppActivated(_ app: NSRunningApplication) {
        previousApp = app
        // Switching to another app abandons an open picker (left open, it would float there, pending).
        // Only regular apps count, so a system prompt shown while browsing does not close it.
        if let picker, app.activationPolicy == .regular {
            pickerAbandoned = true
            picker.cancel(nil)
        }
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the panel, as Spotlight does. Hands-free dictation and the
        // file picker keep it open.
        guard panel.isVisible, picker == nil, !(model.voice.isActive && model.voice.mode == .handsFree) else { return }
        // Dragging a file in from another app starts with a click there, so wait to see where it lands.
        if NSEvent.pressedMouseButtons & 1 != 0 { hideAfterMouseUp() } else { hide(returnFocus: false) }
    }

    private func hideAfterMouseUp() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self else { return }
            stopWaitingForMouseUp()
            // A drop on the panel makes it key again (see `attachDropped`), which arrives just after the mouse-up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.panel.isVisible, !self.panel.isKeyWindow { self.hide(returnFocus: false) }
            }
        }
    }

    private func stopWaitingForMouseUp() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
    }

    /// Called from SwiftUI layout; applied on the next run-loop turn, because resizing a window from
    /// inside a layout pass leaves the frame and the content view out of sync.
    private func resize(to height: CGFloat) {
        guard height > 0 else { return }
        let scheduled = pendingHeight != nil
        pendingHeight = height
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingHeight() }
    }

    private func applyPendingHeight() {
        guard let height = pendingHeight else { return }
        pendingHeight = nil
        measuredHeight = height
        if model.conversation.isEmpty && model.notice == nil { emptyHeight = height }
        guard abs(panel.frame.height - height) > 0.5 else { return }
        if topEdge == 0 { topEdge = panel.frame.maxY }
        panel.setFrame(NSRect(x: panel.frame.minX, y: topEdge - height, width: Self.width, height: height), display: true)
        panel.invalidateShadow()
    }

    /// Nonisolated because AppKit may run an image's drawing handler on any thread.
    private nonisolated static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Local monitors run on the main thread, inside the app's event dispatch.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Panel shortcuts. Returns true when the key was handled and should not reach the text field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editor = panel.firstResponder as? NSTextView
        // Return confirms IME composition (for example Chinese or Japanese input); leave it alone.
        let composing = editor?.hasMarkedText() ?? false

        if !composing, !model.suggestions.isEmpty, handleSuggestionKey(event, flags: flags) { return true }

        switch event.keyCode {
        case 53:  // Escape
            guard !composing else { return false }
            if model.voice.isActive { model.voice.cancel() } else { hide() }
            return true
        case 36, 76:  // Return, keypad Enter
            guard !composing else { return false }
            if flags.contains(.command) {
                model.handOff()
            } else if flags.contains(.shift) || flags.contains(.option) {
                // The field editor treats ⇧↩ as "end editing", so insert the newline here.
                editor?.insertNewlineIgnoringFieldEditor(nil)
            } else if model.voice.isActive {
                model.voice.finish(send: true)
            } else {
                model.submit()
            }
            return true
        default:
            break
        }

        // ⌘U / ⌃U / ⌃W. Checked after Return and the suggestion keys so those keep working, and skipped
        // while an input method is composing so the key still confirms or edits the marked text.
        if !model.isHandingOff, let editor,
            let action = PromptEditing.deletion(
                key: event.charactersIgnoringModifiers ?? "",
                command: flags.contains(.command),
                control: flags.contains(.control),
                option: flags.contains(.option),
                shift: flags.contains(.shift),
                composing: composing)
        {
            PromptEditing.apply(action, to: editor)
            return true
        }

        guard flags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n": model.newConversation()
        case ".": model.cancel()
        case "w": hide()
        case "m": DispatchQueue.main.async { self.showModelMenu() }  // the menu runs its own event loop
        case ",":
            NSWorkspace.shared.open(WispPaths.standard.configFile)
            hide(returnFocus: false)
        case "c" where flags.contains(.shift): model.copyLastAnswer()
        case "a" where flags.contains(.shift): model.attachContextWindow()
        case "o": chooseFiles()
        case "v" where !flags.contains(.shift): return pasteAttachments()
        default: return false
        }
        return true
    }

    /// ↑ and ↓ move through the slash-command suggestions; Tab or Return fills in the highlighted one.
    /// Return on a command that is already typed in full runs it.
    private func handleSuggestionKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125: model.moveSuggestionSelection(by: 1)  // Down
        case 126: model.moveSuggestionSelection(by: -1)  // Up
        case 48: model.acceptSuggestion()  // Tab
        case 36, 76:  // Return, keypad Enter
            guard !model.highlightedCommandIsTyped else { return false }
            model.acceptSuggestion()
        default: return false
        }
        return true
    }

    /// ⌘V with files (copied in Finder) or an image on the pasteboard attaches them; text pastes normally.
    private func pasteAttachments() -> Bool {
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            model.attach(files: fileURLs)
            return true
        }
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            model.attach(image: image)
            return true
        }
        return false
    }

    // MARK: Attachments

    /// The paperclip menu: the window of the app you came from, or files from disk.
    func showAttachMenu() {
        guard panel.isVisible else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let app = model.contextAppName
        let window = ActionItem(title: app.map { "Attach \($0) Window" } ?? "Attach Window", enabled: app != nil) {
            [weak self] in self?.model.attachContextWindow()
        }
        window.keyEquivalent = "a"
        window.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(window)
        let files = ActionItem(title: "Choose Files…") { [weak self] in self?.chooseFiles() }
        files.keyEquivalent = "o"
        files.keyEquivalentModifierMask = [.command]
        menu.addItem(files)
        let point = effectView.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: effectView)
    }

    func chooseFiles() {
        guard panel.isVisible, picker == nil else { return }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = true
        picker.prompt = "Attach"
        picker.level = .modalPanel  // above the floating panel
        self.picker = picker
        pickerAbandoned = false
        NSApp.activate()
        picker.begin { [weak self] response in
            guard let self else { return }
            self.picker = nil
            if response == .OK { model.attach(files: picker.urls) }
            if pickerAbandoned { hide(returnFocus: false) } else { show() }
        }
    }

    private func attachDropped(_ urls: [URL]) {
        model.attach(files: urls)
        show()
    }

    // MARK: Model menu

    func showModelMenu() {
        guard panel.isVisible else { return }
        let menu = ModelMenu.make(for: model)
        // Just under the input row, by the model chip on the right.
        menu.popUp(positioning: nil, at: NSPoint(x: Self.width - 260, y: effectView.bounds.height - 50), in: effectView)
    }
}
