import AppKit
import BeltKit
import SwiftUI

/// Owns the app's three windows. A menu bar app has to activate itself to show them.
@MainActor
final class WindowManager {
    private let registry: GadgetRegistry
    private let permissions: PermissionBroker
    private let store: SettingsStore
    private let model: RegistryModel
    private var gallery: NSWindow?
    private var settings: NSWindow?
    private var support: NSWindow?

    init(registry: GadgetRegistry, permissions: PermissionBroker, store: SettingsStore) {
        self.registry = registry
        self.permissions = permissions
        self.store = store
        self.model = RegistryModel(registry: registry, permissions: permissions)
    }

    func showGallery(welcome: Bool) {
        model.refresh()
        let view = GalleryView(model: model, welcome: welcome,
                               openSupport: { [weak self] in self?.showSupport() })
        gallery = present(gallery, title: "Mac Belt", view: view, size: NSSize(width: 760, height: 560))
    }

    func showSettings() {
        model.refresh()
        let view = SettingsView(model: model, settingsFolder: store.directory)
        settings = present(settings, title: "Mac Belt Settings", view: view, size: NSSize(width: 620, height: 520))
    }

    func showSupport() {
        support = present(support, title: "Support Mac Belt", view: SupportView(), size: NSSize(width: 440, height: 560))
    }

    private func present<V: View>(_ existing: NSWindow?, title: String, view: V, size: NSSize) -> NSWindow {
        let window = existing ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.title = title
            w.center()
            return w
        }()
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// SwiftUI-facing wrapper around the registry.
@MainActor
final class RegistryModel: ObservableObject {
    let registry: GadgetRegistry
    let permissions: PermissionBroker

    init(registry: GadgetRegistry, permissions: PermissionBroker) {
        self.registry = registry
        self.permissions = permissions
        let previous = registry.onChange
        registry.onChange = { [weak self] in
            previous?()
            self?.refresh()
        }
    }

    func refresh() { objectWillChange.send() }

    var infos: [GadgetInfo] { registry.infos }
    func isOn(_ id: String) -> Bool { registry.isRunning(id) }
    func error(_ id: String) -> String? { registry.errors[id] }

    func set(_ info: GadgetInfo, on: Bool) {
        if on {
            // Ask for permissions only now, when the user switches the gadget on. Permissions
            // macOS can't report (.unknown) are prompted by macOS itself when first used.
            for p in info.permissions where permissions.status(p) == .notGranted { permissions.request(p) }
        }
        registry.setEnabled(info.id, on)
        refresh()
    }
}
