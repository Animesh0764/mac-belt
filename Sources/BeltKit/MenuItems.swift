import AppKit

/// An NSMenuItem that runs a closure, so gadgets don't need @objc targets.
public final class BeltMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    public init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true,
                key: String = "", handler: (() -> Void)? = nil) {
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
        self.state = checked ? .on : .off
        self.isEnabled = enabled && handler != nil
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    /// A submenu item.
    public convenience init(_ title: String, symbol: String? = nil, submenu items: [NSMenuItem]) {
        self.init(title, symbol: symbol)
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        self.submenu = menu
        self.isEnabled = true
    }

    /// A grey, non-clickable line (status text).
    public static func label(_ title: String, symbol: String? = nil) -> BeltMenuItem {
        BeltMenuItem(title, symbol: symbol, enabled: false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler?() }
}
