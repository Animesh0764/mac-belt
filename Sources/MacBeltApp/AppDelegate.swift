import AppKit
import BeltKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: GadgetRegistry!
    private var statusMenu: StatusMenuController!
    private var windows: WindowManager!
    private let ui = BeltUI()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SettingsStore()
        let hotkeys = HotkeyCenter()
        let permissions = PermissionBroker()
        let events = EventBus()
        let ui = self.ui
        registry = GadgetRegistry(types: Gadgets.all, store: store) { info in
            GadgetContext(id: info.id, store: store, hotkeys: hotkeys, permissions: permissions,
                          events: events, ui: ui)
        }
        windows = WindowManager(registry: registry, permissions: permissions, store: store)
        statusMenu = StatusMenuController(registry: registry, ui: ui, windows: windows)

        let firstLaunch = !registry.state.onboardingDone
        if firstLaunch {
            for id in Gadgets.onByDefault { registry.setEnabled(id, true) }
            registry.markOnboardingDone()
        }
        let disabled = registry.startEnabledAtLaunch()
        if !disabled.isEmpty {
            ui.toast("\(disabled.joined(separator: ", ")) crashed last time and was switched off",
                     symbol: "exclamationmark.triangle")
        }
        if firstLaunch { windows.showGallery(welcome: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stopAll()
    }

    // Re-opening the app from Finder/Spotlight while it's running shows the gallery,
    // since a menu bar app has no window to bring back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showGallery(welcome: false)
        return false
    }
}
