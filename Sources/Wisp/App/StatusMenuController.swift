import AppKit
import ServiceManagement
import WispCore

/// The sparkle in the menu bar and its menu, rebuilt each time it opens.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let showPanel: @MainActor () -> Void
    private let startVoice: @MainActor () -> Void

    init(model: AppModel, showPanel: @escaping @MainActor () -> Void, startVoice: @escaping @MainActor () -> Void) {
        self.model = model
        self.showPanel = showPanel
        self.startVoice = startVoice
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Wisp")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = model.config
        menu.addItem(ActionItem(title: "Ask Anything   \(HotkeySpec.display(config.hotkey)) (hold to talk)", handler: showPanel))
        menu.addItem(ActionItem(title: "Voice   \(HotkeySpec.display(config.voiceHotkey))", handler: startVoice))
        menu.addItem(
            ActionItem(title: "New Conversation") { [model, showPanel] in
                model.newConversation()
                showPanel()
            })
        menu.addItem(
            ActionItem(title: "Continue in Ghostty", enabled: model.sessionID != nil) { [model] in model.continueInGhostty() })
        menu.addItem(submenu("Open Recent in Ghostty", recentItems()))
        menu.addItem(submenu("Model", modelItems()))

        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Edit Config…") { NSWorkspace.shared.open(WispPaths.standard.configFile) })
        menu.addItem(
            ActionItem(title: "Launch at Login", checked: SMAppService.mainApp.status == .enabled) { Self.toggleLaunchAtLogin() })
        menu.addItem(ActionItem(title: "Restart Agent") { [model] in model.restartAgent() })
        menu.addItem(ActionItem(title: "Show Logs") { NSWorkspace.shared.open(WispPaths.standard.logs) })
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        menu.addItem(ActionItem(title: "Wisp \(version)", enabled: false) {})
        menu.addItem(ActionItem(title: "Quit Wisp") { NSApp.terminate(nil) })
    }

    private func recentItems() -> [NSMenuItem] {
        model.refreshHistoryTitles()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let items = model.history.entries.map { entry in
            let when = formatter.localizedString(for: entry.updatedAt, relativeTo: Date())
            return ActionItem(title: "\(entry.title)  ·  \(when)") { [model] in model.openRecent(entry) } as NSMenuItem
        }
        return items.isEmpty ? [ActionItem(title: "No conversations yet", enabled: false) {}] : items
    }

    private func modelItems() -> [NSMenuItem] {
        let menu = ModelMenu.make(for: model)
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
