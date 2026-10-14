import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = AppConfig()
    private var configDate: Date?
    private var model: SpotlightModel!
    private(set) var panel: PanelController!
    private let hotkeys = HotKeyCenter()
    private var statusItem: NSStatusItem!
    private var control: ControlServer?

    // Hold-to-talk state for the main hotkey.
    private var hotkeyDown = false
    private var panelWasOpen = false
    private var holdStartedVoice = false
    private var holdTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (loaded, error) = AppConfig.load()
        config = loaded
        configDate = Self.configModificationDate()
        model = SpotlightModel(config: config)
        panel = PanelController(model: model)
        model.onHistoryChanged = { [weak self] in self?.rebuildMenu() }
        setUpStatusItem()
        registerHotkeys()
        control = ControlServer(delegate: self)
        model.warmUp()
        if let error { model.notice = error }
        handleTerminationSignal()
        appLog("launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private var signalSource: DispatchSourceSignal?

    /// `kill`/`make install` send SIGTERM; route it through a normal quit so the agent is stopped too.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    // MARK: Hotkeys

    /// Returns a message when a shortcut could not be registered.
    @discardableResult
    private func registerHotkeys() -> String? {
        hotkeys.unregisterAll()
        var failures: [String] = []
        if !hotkeys.register(config.hotkey, pressed: { [weak self] in self?.mainHotkeyPressed() },
                             released: { [weak self] in self?.mainHotkeyReleased() }) {
            failures.append(config.hotkey)
        }
        if !hotkeys.register(config.voiceHotkey, pressed: { [weak self] in self?.voiceHotkeyPressed() }) {
            failures.append(config.voiceHotkey)
        }
        guard !failures.isEmpty else { return nil }
        let message = "Could not register \(failures.joined(separator: ", ")). Another app may own it; change it in the config (⌘,)."
        model.notice = message
        appLog("hotkey registration failed: \(failures)")
        return message
    }

    /// Tap toggles the panel. Holding past 0.3 s starts push-to-talk; releasing sends.
    private func mainHotkeyPressed() {
        guard !hotkeyDown else { return }  // ignore key repeat
        hotkeyDown = true
        holdStartedVoice = false
        panelWasOpen = panel.isVisible
        if !panelWasOpen { showPanel() }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hotkeyDown, !self.model.voice.active else { return }
                self.holdStartedVoice = true
                if !self.panel.isVisible { self.showPanel() }
                self.model.startVoice(mode: .pushToTalk)
            }
        }
    }

    private func mainHotkeyReleased() {
        hotkeyDown = false
        holdTimer?.invalidate()
        if holdStartedVoice {
            model.finishVoice(send: true)
        } else if panelWasOpen {
            if model.voice.active {
                model.finishVoice(send: true)
            } else {
                panel.hide()
            }
        }
    }

    private func voiceHotkeyPressed() {
        if model.voice.active {
            model.finishVoice(send: true)
        } else {
            showPanel()
            model.startVoice(mode: .handsFree)
        }
    }

    func showPanel() {
        reloadConfigIfChanged()
        panel.show()
    }

    func togglePanel() {
        if panel.isVisible { panel.hide() } else { showPanel() }
    }

    func toggleVoice() { voiceHotkeyPressed() }

    // MARK: Config

    private static func configModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppConfig.fileURL.path))?[.modificationDate] as? Date
    }

    private func reloadConfigIfChanged() {
        let date = Self.configModificationDate()
        guard date != configDate else { return }
        reloadConfig()
    }

    @objc func reloadConfig() {
        let (loaded, error) = AppConfig.load()
        configDate = Self.configModificationDate()
        let hotkeysChanged = loaded.hotkey != config.hotkey || loaded.voiceHotkey != config.voiceHotkey
        config = loaded
        model.apply(config: loaded)
        let hotkeyError = hotkeysChanged ? registerHotkeys() : nil
        rebuildMenu()
        model.notice = error ?? hotkeyError ?? "Config reloaded"
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Grok Spotlight")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(item("Ask Grok  (\(HotKeyCenter.display(config.hotkey)), hold to talk)", #selector(menuShow)))
        menu.addItem(item("Voice  (\(HotKeyCenter.display(config.voiceHotkey)))", #selector(menuVoice)))
        menu.addItem(item("New Conversation", #selector(menuNew)))
        let continueItem = item("Continue in Ghostty", #selector(menuGhostty))
        continueItem.isEnabled = model.sessionId != nil
        menu.addItem(continueItem)

        let recent = NSMenuItem(title: "Open Recent in Ghostty", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for entry in model.history.entries {
            let when = formatter.localizedString(for: entry.updatedAt, relativeTo: Date())
            let historyItem = item("\(entry.title)  ·  \(when)", #selector(menuOpenRecent(_:)))
            historyItem.representedObject = entry.id
            submenu.addItem(historyItem)
        }
        if submenu.items.isEmpty {
            let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        recent.submenu = submenu
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(item("Edit Config…", #selector(menuEditConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfig)))
        let login = item("Launch at Login", #selector(menuToggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Restart Grok Agent", #selector(menuRestart)))
        menu.addItem(item("Show Logs", #selector(menuLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Grok Spotlight", #selector(menuQuit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuShow() { showPanel() }
    @objc private func menuVoice() { voiceHotkeyPressed() }
    @objc private func menuNew() { model.newConversation(); showPanel() }
    @objc private func menuGhostty() { model.openInGhostty() }
    @objc private func menuRestart() { model.restartAgent() }
    @objc private func menuEditConfig() { NSWorkspace.shared.open(AppConfig.fileURL) }
    @objc private func menuLogs() { NSWorkspace.shared.open(AppPaths.logs) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuOpenRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = model.history.entries.first(where: { $0.id == id }) else { return }
        model.openHistory(entry)
    }

    @objc private func menuToggleLogin() {
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
        rebuildMenu()
    }

    // MARK: Control commands

    var spotlightModel: SpotlightModel { model }
}

