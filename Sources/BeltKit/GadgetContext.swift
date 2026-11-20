import Foundation
import os

/// Everything a gadget is allowed to use. Handed to `Gadget.init(context:)`.
@MainActor
public final class GadgetContext {
    public let id: String
    public let settings: GadgetSettings
    public let hotkeys: HotkeyCenter
    public let permissions: PermissionBroker
    public let events: EventBus
    public let ui: BeltUI
    public let log: Logger

    public init(id: String, store: SettingsStore, hotkeys: HotkeyCenter, permissions: PermissionBroker,
                events: EventBus, ui: BeltUI) {
        self.id = id
        self.settings = GadgetSettings(store: store, key: "gadget.\(id)")
        self.hotkeys = hotkeys
        self.permissions = permissions
        self.events = events
        self.ui = ui
        self.log = Logger(subsystem: "io.github.macbelt.app", category: id)
    }

    /// Show (or clear with nil) a small SF Symbol in the menu bar icon, e.g. while Awake is on.
    public func setBadge(_ symbol: String?, priority: Int = 0) {
        ui.setBadge(symbol, for: id, priority: priority)
    }

    public func toast(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.8) {
        ui.toast(text, symbol: symbol, duration: duration)
    }
}
