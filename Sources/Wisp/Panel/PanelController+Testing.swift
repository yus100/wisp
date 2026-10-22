import AppKit
import WebKit

/// Hooks for `Wisp ctl` (and scripts/smoke-test.sh), so the panel can be checked without a screen recording
/// permission or a person at the keyboard, plus the renderer behind the README screenshots.
extension PanelController {
    private static var capturingPanels: Set<ObjectIdentifier> = []

    /// The panel's content at `scale` pixels per point, on a transparent background (without vibrancy).
    /// Returns nil if WebKit cannot finish rendering or capturing within four seconds.
    func renderContent(scale: CGFloat = 1) -> NSBitmapImageRep? {
        let identity = ObjectIdentifier(self)
        guard scale.isFinite, scale > 0, Self.capturingPanels.insert(identity).inserted else { return nil }
        defer { Self.capturingPanels.remove(identity) }
        // Keep the synchronous screenshot/ctl API without blocking WebKit's main-run-loop callbacks.
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        guard waitForSnapshotLayout(until: deadline) else { return nil }
        let bounds = hostingView.bounds
        let regions = webSnapshotRegions()
        var images = [Int: NSImage]()
        var completed = 0
        var failed = false
        for (index, region) in regions.enumerated() where !region.rect.isEmpty {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = region.rect
            // WebKit multiplies snapshotWidth (points) by its backing scale.
            let backingScale = region.view.window?.backingScaleFactor ?? 1
            configuration.snapshotWidth = NSNumber(value: Double(region.rect.width * scale / backingScale))
            region.view.takeSnapshot(with: configuration) { image, error in
                completed += 1
                if let image, error == nil { images[index] = image } else { failed = true }
            }
        }
        let expected = regions.filter { !$0.rect.isEmpty }.count
        guard pumpSnapshotRunLoop(until: deadline, while: { completed < expected }), !failed else { return nil }
        hostingView.layoutSubtreeIfNeeded()
        // A resize or scroll during the asynchronous snapshots invalidates their placement.
        guard hostingView.bounds == bounds, webSnapshotRegions() == regions,
            bounds.width > 0, bounds.height > 0,
            let width = Int(exactly: ceil(bounds.width * scale)),
            let height = Int(exactly: ceil(bounds.height * scale)),
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else { return nil }
        // AppKit's view drawing omits WebKit's remote layers; composite only their visible portions below.
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.saveGState()
        hostingView.displayIgnoringOpacity(bounds, in: context)
        context.cgContext.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, region) in regions.enumerated() {
            guard let image = images[index] else { continue }
            var destination = region.destination.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            if hostingView.isFlipped { destination.origin.y = bounds.height - destination.maxY }
            // Some hosting hierarchies also draw cached WebKit pixels; do not blend the answer twice.
            context.cgContext.clear(destination)
            image.draw(
                in: destination, from: .zero, operation: .sourceOver, fraction: region.alpha,
                respectFlipped: false, hints: nil)
        }
        representation.size = bounds.size
        return representation
    }

    private struct WebSnapshotRegion: Equatable {
        let view: WKWebView
        let bounds: NSRect
        let rect: NSRect
        let destination: NSRect
        let alpha: CGFloat
    }

    private func webSnapshotRegions() -> [WebSnapshotRegion] {
        var regions: [WebSnapshotRegion] = []
        func visit(_ view: NSView, alpha: CGFloat) {
            guard !view.isHidden, alpha * view.alphaValue > 0 else { return }
            let alpha = alpha * view.alphaValue
            if let webView = view as? WKWebView {
                let visible = hostingView.convert(webView.visibleRect, from: webView).intersection(hostingView.bounds)
                let rect =
                    visible.isEmpty ? NSRect.zero : webView.convert(visible, from: hostingView).intersection(webView.bounds)
                regions.append(
                    WebSnapshotRegion(
                        view: webView, bounds: webView.bounds, rect: rect,
                        destination: rect.isEmpty ? .zero : hostingView.convert(rect, from: webView), alpha: alpha))
            } else {
                for child in view.subviews { visit(child, alpha: alpha) }
            }
        }
        visit(hostingView, alpha: 1)
        return regions
    }

    private func waitForSnapshotLayout(until deadline: TimeInterval) -> Bool {
        var previousRegions: [WebSnapshotRegion] = []
        var previousDocuments: [String] = []
        var previousBounds = NSRect.zero
        var stableSince = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            hostingView.layoutSubtreeIfNeeded()
            let regions = webSnapshotRegions()
            let bounds = hostingView.bounds
            var documents: [String] = []
            var ready = true
            for region in regions {
                guard !region.view.isLoading else {
                    ready = false
                    break
                }
                var finished = false
                var document: String?
                // Fonts can finish after navigation, and their height callbacks resize the native scroll view.
                region.view.evaluateJavaScript(
                    """
                    document.readyState === 'complete' && document.fonts.status === 'loaded'
                        ? document.documentElement.outerHTML : null
                    """
                ) { value, _ in
                    document = value as? String
                    finished = true
                }
                guard pumpSnapshotRunLoop(until: deadline, while: { !finished }) else { return false }
                guard let document else {
                    ready = false
                    break
                }
                documents.append(document)
            }
            if !ready || regions != previousRegions || documents != previousDocuments || bounds != previousBounds {
                stableSince = ProcessInfo.processInfo.systemUptime
            } else if ProcessInfo.processInfo.systemUptime - stableSince >= 0.1 {
                return true
            }
            previousRegions = regions
            previousDocuments = documents
            previousBounds = bounds
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    private func pumpSnapshotRunLoop(until deadline: TimeInterval, while pending: () -> Bool) -> Bool {
        while pending() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
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
        guard let representation = renderContent() else { return nil }
        let bounds = NSRect(origin: .zero, size: representation.size)
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
