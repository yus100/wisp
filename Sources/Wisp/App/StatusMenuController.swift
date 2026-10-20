import AppKit
import Combine
import WispCore

/// The sparkle in the menu bar and its menu, rebuilt each time it opens.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let showPanel: @MainActor () -> Void
    private let startVoice: @MainActor () -> Void
    private var answerWaiting: AnyCancellable?

    init(model: AppModel, showPanel: @escaping @MainActor () -> Void, startVoice: @escaping @MainActor () -> Void) {
        self.model = model
        self.showPanel = showPanel
        self.startVoice = startVoice
        super.init()
        answerWaiting = model.$answerWaiting.sink { [weak self] waiting in self?.showIcon(answerWaiting: waiting) }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// The sparkle, with a dot while an answer is waiting.
    private func showIcon(answerWaiting: Bool) {
        guard let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Wisp") else { return }
        let image = answerWaiting ? Self.badged(sparkle) : sparkle
        image.isTemplate = true
        image.accessibilityDescription = answerWaiting ? "Wisp, answer ready" : "Wisp"
        statusItem.button?.image = image
    }

    /// Nonisolated because AppKit may run an image's drawing handler on any thread.
    private nonisolated static func badged(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            let size = rect.width * 0.34
            let dot = NSRect(x: rect.maxX - size, y: rect.maxY - size, width: size, height: size)
            let gap = rect.width * 0.08
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -gap, dy: -gap)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = model.config
        if model.answerWaiting {
            menu.addItem(ActionItem(title: "Show Answer", handler: showPanel))
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem(title: "Ask Anything   \(HotkeySpec.display(config.hotkey)) (hold to talk)", handler: showPanel))
        menu.addItem(ActionItem(title: "Voice   \(HotkeySpec.display(config.voiceHotkey))", handler: startVoice))
        menu.addItem(
            ActionItem(title: "New Conversation") { [model, showPanel] in
                model.newConversation()
                showPanel()
            })
        menu.addItem(
            ActionItem(title: "History…") { [model, showPanel] in
                showPanel()
                model.showHistory()
            })
        menu.addItem(
            ActionItem(title: "Continue in Ghostty", enabled: model.sessionID != nil) { [model] in model.continueInGhostty() })
        menu.addItem(submenu("Open Recent in Ghostty", recentItems()))
        menu.addItem(submenu("Model", modelItems()))

        menu.addItem(.separator())
        menu.addItem(ActionItem(title: "Edit Config…") { NSWorkspace.shared.open(WispPaths.standard.configFile) })
        menu.addItem(
            ActionItem(title: "Launch at Login", checked: config.launchAtLogin) { [model] in model.toggleLaunchAtLogin() })
        menu.addItem(ActionItem(title: "Restart Agent") { [model] in model.restartAgent() })
        menu.addItem(ActionItem(title: "Show Logs") { NSWorkspace.shared.open(WispPaths.standard.logs) })
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        menu.addItem(ActionItem(title: "Wisp \(version)", enabled: false) {})
        menu.addItem(ActionItem(title: "Quit Wisp") { NSApp.terminate(nil) })
    }

    /// The newest conversations; History… (⌘Y in the panel) searches all of them.
    private func recentItems() -> [NSMenuItem] {
        model.refreshHistory()
        let items = model.history.entries.prefix(20).map { entry in
            ActionItem(title: "\(entry.title)  ·  \(RelativeTime.describe(entry.updatedAt))") { [model] in
                model.openRecent(entry)
            } as NSMenuItem
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

}
