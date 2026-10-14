import AppKit
import WispCore

/// The model and reasoning-effort menu, shared by the panel (⌘M, model chip) and the menu bar.
@MainActor
enum ModelMenu {
    static func make(for model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItems(to: menu, for: model)
        return menu
    }

    static func addItems(to menu: NSMenu, for model: AppModel) {
        let current = model.effectiveModelID
        menu.addItem(.sectionHeader(title: "Model"))
        if model.catalog.models.isEmpty {
            let loading = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }
        for option in model.catalog.models {
            let suffix = option.id == model.catalog.defaultModelID ? "   (Grok Build default)" : ""
            menu.addItem(ActionItem(title: option.name + suffix, checked: option.id == current) { model.selectModel(option.id) })
        }
        guard let current else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Reasoning effort"))
        for effort in model.catalog.efforts(for: current) {
            menu.addItem(ActionItem(title: AppModel.effortLabel(effort), checked: effort == model.config.reasoningEffort) {
                model.selectEffort(effort)
            })
        }
    }
}

/// A menu item that runs a closure, so menus can be built without a target object per item.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// AppKit invokes menu actions on the main thread.
    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
