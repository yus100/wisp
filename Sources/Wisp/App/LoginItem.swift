import AppKit
import ServiceManagement
import WispCore

/// Keeps Wisp's login item in line with `launchAtLogin`, so the hotkeys work from the moment you log in.
@MainActor
enum LoginItem {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// Registers or unregisters Wisp as a login item. Returns a problem to show, if any.
    static func apply(_ wanted: Bool) -> Notice? {
        // A copy run from the build folder must not replace the installed one as the login item.
        guard Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else {
            Log.info("launch at login: skipped, \(Bundle.main.bundlePath) is not in an Applications folder")
            return nil
        }
        let service = SMAppService.mainApp
        do {
            if wanted, service.status != .enabled { try service.register() }
            if !wanted, service.status == .enabled { try service.unregister() }
        } catch {
            Log.info("launch at login: \(error.localizedDescription)")
            return Notice(
                "Could not turn \(wanted ? "on" : "off") Launch at Login: \(error.localizedDescription)",
                actionTitle: "Open Settings", actionURL: settingsURL)
        }
        Log.info("launch at login: \(statusName)")
        if wanted, service.status == .requiresApproval {
            return Notice(
                "Allow Wisp under Login Items in System Settings so it starts when you log in.",
                actionTitle: "Open Settings", actionURL: settingsURL)
        }
        return nil
    }

    static var statusName: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notRegistered: "off"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}
