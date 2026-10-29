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
        let catalog = model.catalog
        if catalog.models.isEmpty {
            menu.addItem(.sectionHeader(title: "Model"))
            let loading = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        } else if catalog.models.allSatisfy({ $0.group == nil }) {
            menu.addItem(.sectionHeader(title: "Model"))
            for option in catalog.models { menu.addItem(modelItem(option, current: current, catalog: catalog, model: model)) }
        } else {
            var lastGroup: String?
            for option in catalog.models {
                let group = option.group ?? "Model"
                if group != lastGroup {
                    menu.addItem(.sectionHeader(title: group))
                    lastGroup = group
                }
                menu.addItem(modelItem(option, current: current, catalog: catalog, model: model))
            }
        }
        guard let current else { return }
        let efforts = catalog.efforts(for: current)
        guard !efforts.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Reasoning effort"))
        let shown = model.displayedEffort(for: current)
        for effort in efforts {
            menu.addItem(
                ActionItem(title: catalog.effortLabel(effort, for: current), checked: effort == shown) {
                    model.selectEffort(effort)
                })
        }
    }

    private static func modelItem(
        _ option: ModelCatalog.Model, current: String?, catalog: ModelCatalog, model: AppModel
    ) -> NSMenuItem {
        let suffix = option.id == catalog.defaultModelID ? "   (Grok Build default)" : ""
        let item = ActionItem(title: catalog.menuTitle(of: option.id) + suffix, checked: option.id == current) {
            model.selectModel(option.id)
        }
        item.toolTip = option.id
        return item
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
