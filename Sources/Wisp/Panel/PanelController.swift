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
    private let layout = PanelLayout()
    private var keyMonitor: Any?
    private var topEdge: CGFloat = 0
    private var measuredHeight: CGFloat = 56
    private var pendingHeight: CGFloat?

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
            onModelMenu: { [weak self] in self?.showModelMenu() })
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
        model.onRequestHide = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Show and hide

    /// Opens on the screen with the mouse, a fifth of the way down.
    func show() {
        model.panelWillShow()
        if !panel.isVisible {
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
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        if model.voice.isActive, model.voice.mode == .pushToTalk { model.voice.cancel() }
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the panel, as Spotlight does. Hands-free dictation keeps going.
        guard panel.isVisible, !(model.voice.isActive && model.voice.mode == .handsFree) else { return }
        hide()
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
        guard abs(panel.frame.height - height) > 0.5 else { return }
        if topEdge == 0 { topEdge = panel.frame.maxY }
        panel.setFrame(NSRect(x: panel.frame.minX, y: topEdge - height, width: Self.width, height: height), display: true)
        panel.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
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

        guard flags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n": model.newConversation()
        case ".": model.cancel()
        case "w": hide()
        case "m": DispatchQueue.main.async { self.showModelMenu() }  // the menu runs its own event loop
        case ",":
            NSWorkspace.shared.open(WispPaths.standard.configFile)
            hide()
        case "c" where flags.contains(.shift): model.copyLastAnswer()
        default: return false
        }
        return true
    }

    // MARK: Model menu

    func showModelMenu() {
        guard panel.isVisible else { return }
        let menu = ModelMenu.make(for: model)
        // Just under the input row, by the model chip on the right.
        menu.popUp(positioning: nil, at: NSPoint(x: Self.width - 260, y: effectView.bounds.height - 50), in: effectView)
    }
}
