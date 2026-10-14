import AppKit

/// Hooks for `Wisp ctl` (and scripts/smoke-test.sh), so the panel can be checked without a screen recording
/// permission or a person at the keyboard.
extension PanelController {
    /// Renders the panel to PNG data over an opaque backdrop (vibrancy is not captured).
    func snapshotPNG() -> Data? {
        let bounds = effectView.bounds
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        hostingView.cacheDisplay(in: bounds, to: representation)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
            representation.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Delivers a key press through the normal event path: the panel's key monitor, then the text field.
    func simulateKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    var frameDescription: String {
        "panel \(panel.frame), content \(effectView.bounds)"
    }
}
