import AppKit
import BeltKit

/// The single Mac Belt menu bar icon and its menu. The menu is rebuilt every time it
/// opens, so gadgets can show live state ("47 min left").
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let registry: GadgetRegistry
    private let ui: BeltUI
    private let windows: WindowManager
    static let defaultSymbol = "wrench.and.screwdriver"

    init(registry: GadgetRegistry, ui: BeltUI, windows: WindowManager) {
        self.registry = registry
        self.ui = ui
        self.windows = windows
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        ui.onBadgeChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    private func updateIcon() {
        let symbol = ui.currentBadge ?? Self.defaultSymbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mac Belt")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Mac Belt"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let running = registry.runningGadgets
        if running.isEmpty {
            menu.addItem(BeltMenuItem.label("No gadgets are on"))
        }
        for gadget in running {
            let info = type(of: gadget).info
            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(
                string: info.name.uppercased(),
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor])
            header.isEnabled = false
            menu.addItem(header)
            gadget.menuItems().forEach(menu.addItem)
            menu.addItem(.separator())
        }
        if running.isEmpty { menu.addItem(.separator()) }

        menu.addItem(BeltMenuItem("Gadgets…", symbol: "square.grid.2x2") { [weak self] in
            self?.windows.showGallery(welcome: false)
        })
        menu.addItem(BeltMenuItem("Settings…", symbol: "gearshape", key: ",") { [weak self] in
            self?.windows.showSettings()
        })
        menu.addItem(BeltMenuItem("Support Mac Belt…", symbol: "cup.and.saucer") { [weak self] in
            self?.windows.showSupport()
        })
        menu.addItem(.separator())
        menu.addItem(BeltMenuItem("Quit Mac Belt", key: "q") { NSApp.terminate(nil) })
    }
}
