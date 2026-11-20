import AppKit

// Menu bar only (LSUIElement in Info.plist; also enforced here for `swift run`).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
