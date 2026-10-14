import AppKit
import SwiftUI

/// Borderless floating panel that takes keyboard focus without activating the app, like Spotlight.
final class WispPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: WispModel
    private let panel: WispPanel
    private let effectView = NSVisualEffectView()
    private var hostingView: NSHostingView<WispView>!
    private var keyMonitor: Any?
    private let width: CGFloat = 720
    private let cornerRadius: CGFloat = 16
    private var topEdge: CGFloat = 0
    private var pendingHeight: CGFloat?
    private var measuredHeight: CGFloat = 56

    init(model: WispModel) {
        self.model = model
        panel = WispPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 60),
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
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.maskImage = Self.roundedMask(radius: cornerRadius)

        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.62
        let root = WispView(model: model, width: width, maxConversationHeight: maxHeight - 120) { [weak self] height in
            self?.resize(to: height)
        }
        hostingView = NSHostingView(rootView: root)
        // The panel height follows the measured SwiftUI height (see `resize`); constraints derived from
        // the hosting view's own size would keep the window from shrinking.
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

    var geometry: String {
        "frame=\(panel.frame) content=\(effectView.bounds) hosting=\(hostingView.frame)"
    }

    // MARK: Show / hide

    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if !panel.isVisible, let frame = screen?.visibleFrame {
            topEdge = frame.maxY - frame.height * 0.2
            let height = measuredHeight
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: topEdge - height, width: width, height: height), display: false)
        }
        model.panelWillShow()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        if model.voice.active && model.voice.mode == .pushToTalk { model.cancelVoice() }
        panel.orderOut(nil)
        removeKeyMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else dismisses the panel, as Spotlight does. Hands-free voice keeps running.
        guard panel.isVisible else { return }
        if model.voice.active && model.voice.mode == .handsFree { return }
        appLog("panel lost focus (frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")); hiding")
        hide()
    }

    /// Called from SwiftUI layout; applied on the next run loop turn because resizing the window
    /// from inside a layout pass leaves the frame and content view out of sync.
    private func resize(to height: CGFloat) {
        guard height > 0 else { return }
        let schedule = pendingHeight == nil
        pendingHeight = height
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.applyPendingHeight() }
        }
    }

    private func applyPendingHeight() {
        guard let height = pendingHeight else { return }
        pendingHeight = nil
        measuredHeight = height
        guard abs(panel.frame.height - height) > 0.5 else { return }
        if topEdge == 0 { topEdge = panel.frame.maxY }
        panel.setFrame(NSRect(x: panel.frame.minX, y: topEdge - height, width: width, height: height), display: true)
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled here and should not reach the text field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false

        switch event.keyCode {
        case 53:  // esc
            if composing { return false }
            if model.voice.active {
                model.cancelVoice()
            } else {
                hide()
            }
            return true
        case 36, 76:  // return, enter
            if composing { return false }
            if command {
                model.openInGhostty()
                return true
            }
            if flags.contains(.shift) || flags.contains(.option) {
                // The field editor treats ⇧↩ as "end editing"; insert the newline ourselves.
                guard let editor = panel.firstResponder as? NSTextView else { return false }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if model.voice.active {
                model.finishVoice(send: true)
            } else {
                model.submit()
            }
            return true
        default:
            break
        }
        guard command else { return false }
        switch key {
        case "n": model.newConversation(); return true
        case ".": model.cancel(); return true
        case "w": hide(); return true
        case "c" where flags.contains(.shift): model.copyLastAnswer(); return true
        case ",": NSWorkspace.shared.open(AppConfig.fileURL); hide(); return true
        default: return false
        }
    }

    // MARK: Testing

    /// Renders the panel contents to a PNG (over an opaque backdrop, since vibrancy is not captured).
    func snapshot(to url: URL) {
        let bounds = effectView.bounds
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hostingView.cacheDisplay(in: bounds, to: rep)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: self.cornerRadius, yRadius: self.cornerRadius).fill()
            rep.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Delivers a synthetic key press through the normal event path (local monitor, then text field).
    func simulateKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
