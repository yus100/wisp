import AppKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots an app's frontmost window with ScreenCaptureKit, for "Attach Window".
enum WindowCapture {
    enum Failure: LocalizedError {
        case notPermitted
        case noWindow(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                "Wisp needs Screen Recording permission to attach a window. Turn it on in System Settings, then reopen Wisp."
            case .noWindow(let app):
                "\(app) has no window on screen to attach."
            }
        }

        var settingsURL: URL? {
            if case .notPermitted = self {
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            return nil
        }
    }

    /// Writes a PNG of `app`'s front window into `directory` and returns its URL.
    static func capture(_ app: NSRunningApplication, into directory: URL) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; afterwards the user grants it in System Settings.
            CGRequestScreenCaptureAccess()
            throw Failure.notPermitted
        }
        let name = app.localizedName ?? "The app"
        guard let windowID = frontWindowID(of: app.processIdentifier) else { throw Failure.noWindow(name) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw Failure.noWindow(name)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        let file = directory.appending(path: "\(name) window \(AppModel.stamp()).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// The app's frontmost normal window. CGWindowList returns windows front to back, and IDs and
    /// owners are readable without Screen Recording permission.
    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 60,
                let id = window[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return id
        }
        return nil
    }
}
