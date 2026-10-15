import AppKit

/// Hooks for `Wisp ctl` (and scripts/smoke-test.sh), so the panel can be checked without a screen recording
/// permission or a person at the keyboard, plus the renderer behind the README screenshots.
extension PanelController {
    /// The panel's SwiftUI content at `scale` pixels per point, on a transparent background
    /// (vibrancy is not captured).
    func renderContent(scale: CGFloat = 1) -> NSBitmapImageRep? {
        let bounds = hostingView.bounds
        guard bounds.width > 0, bounds.height > 0,
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        // Draw into a scaled context directly; cacheDisplay at a non-native scale paints an opaque background.
        context.cgContext.scaleBy(x: scale, y: scale)
        hostingView.displayIgnoringOpacity(bounds, in: context)
        representation.size = bounds.size
        return representation
    }

    /// Lays the panel out offscreen at the height its content reports, without showing it.
    func layOutOffscreen(maxConversationHeight: CGFloat) {
        layout.maxConversationHeight = maxConversationHeight
        // SwiftUI settles over a few run-loop turns: the conversation reports its height, then the panel resizes.
        for _ in 0..<8 {
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Renders the panel to PNG data over an opaque backdrop.
    func snapshotPNG() -> Data? {
        let bounds = effectView.bounds
        guard let representation = renderContent() else { return nil }
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
        guard
            let event = NSEvent.keyEvent(
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
