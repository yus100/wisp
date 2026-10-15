import AppKit
import WispCore

/// Builds the app's objects and connects the hotkeys, config, panel, and menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = WispPaths.standard
    private let hotkeys = HotkeyController()
    private var configStore: ConfigStore!
    private var model: AppModel!
    private var panel: PanelController!
    private var statusMenu: StatusMenuController?
    private var control: ControlServer?
    private var notifier: AnswerNotifier?
    private var terminationSignal: DispatchSourceSignal?
    private var panelWasOpenOnPress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.enable(in: paths.logs)
        configStore = ConfigStore(file: paths.configFile)
        model = AppModel(configStore: configStore, paths: paths)
        panel = PanelController(model: model)
        statusMenu = StatusMenuController(
            model: model,
            showPanel: { [weak self] in self?.panel.show() },
            startVoice: { [weak self] in self?.toggleVoice() })
        control = ControlServer(model: model, panel: panel) { [weak self] in self?.configStore.config.remoteControl ?? false }

        configStore.onChange = { [weak self] old, new in self?.configChanged(from: old, to: new) }
        configStore.onReloadProblem = { [weak self] problem in self?.model.notice = Notice(problem) }
        hotkeys.onMainKey = { [weak self] in self?.mainKey($0) }
        hotkeys.onVoiceKey = { [weak self] in self?.toggleVoice() }
        if let problem = registerHotkeys() ?? configStore.problem { model.notice = Notice(problem) }
        if let problem = LoginItem.apply(configStore.config.launchAtLogin), model.notice == nil { model.notice = problem }

        notifyWhenAnswersFinishInBackground()
        model.pruneOldAttachments()
        model.warmUp()
        quitCleanlyOnSIGTERM()
        Log.info("launched")
    }

    /// Opening Wisp again from Finder, Spotlight, or `open` shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: Hotkeys

    private func registerHotkeys() -> String? {
        hotkeys.register(mainKey: configStore.config.hotkey, voiceKey: configStore.config.voiceHotkey)
    }

    /// Tap toggles the panel; hold talks (push-to-talk) and sends on release.
    private func mainKey(_ event: HotkeyController.MainKeyEvent) {
        let voice = model.voice
        switch event {
        case .pressed:
            panelWasOpenOnPress = panel.isVisible
            if !panel.isVisible { panel.show() }
        case .holdBegan:
            guard !voice.isActive else { return }
            if !panel.isVisible { panel.show() }
            model.startVoice(.pushToTalk)
        case .released(held: true):
            if voice.isActive, voice.mode == .pushToTalk { voice.finish(send: true) }
        case .released(held: false):
            guard panelWasOpenOnPress else { return }
            if voice.isActive { voice.finish(send: true) } else { panel.hide() }
        }
    }

    private func toggleVoice() {
        if model.voice.isActive {
            model.voice.finish(send: true)
        } else {
            panel.show()
            model.startVoice(.handsFree)
        }
    }

    /// Ask, close the panel, and find out when the answer is ready: a dot on the menu bar icon, and a
    /// notification (clicking it reopens the panel) when macOS allows them.
    private func notifyWhenAnswersFinishInBackground() {
        // Notifications need an app bundle; a bare `swift run` binary has none.
        if Bundle.main.bundleIdentifier != nil {
            notifier = AnswerNotifier { [weak self] in self?.panel.show() }
        }
        model.onAnswerFinished = { [weak self] turn in
            guard let self, !panel.isVisible else { return }
            model.answerWaiting = true
            if configStore.config.notifyWhenDone { notifier?.notify(turn) }
        }
    }

    // MARK: Config

    /// Changes apply at once, so only problems get a notice.
    private func configChanged(from old: WispConfig, to new: WispConfig) {
        model.configDidChange(from: old, to: new)
        if old.hotkey != new.hotkey || old.voiceHotkey != new.voiceHotkey, let problem = registerHotkeys() {
            model.notice = Notice(problem)
        }
        if old.launchAtLogin != new.launchAtLogin, let problem = LoginItem.apply(new.launchAtLogin) {
            model.notice = problem
        }
    }

    /// `kill` and `make install` send SIGTERM; route it through a normal quit so the agent stops too.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }
}
