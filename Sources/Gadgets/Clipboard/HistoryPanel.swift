import AppKit
import ClipboardCore
import SwiftUI

/// The floating history window (⌃⌘V). It doesn't activate Mac Belt, so the app you were
/// in stays frontmost and "paste directly" lands there.
@MainActor
final class HistoryPanel {
    final class Model: ObservableObject {
        @Published var query = ""
        @Published var items: [ClipItem] = []
        @Published var selection = 0
        @Published var now = Date()
        var pasteDirectly = false
    }

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let model = Model()
    private weak var gadget: ClipboardGadget?
    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var clock: Timer?
    private var querySink: Any?

    init(gadget: ClipboardGadget) {
        self.gadget = gadget
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let gadget else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.query = ""
        model.selection = 0
        model.pasteDirectly = gadget.model.settings.pasteDirectly
        reload(force: true)
        // Center on the screen with the mouse.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1))
        }
        panel.makeKeyAndOrderFront(nil)
        installMonitors(panel)
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    /// Refreshes the list. Does nothing while the panel is closed, unless forced.
    func reload(force: Bool = false) {
        guard force || isVisible, let gadget else { return }
        model.items = gadget.history(matching: model.query)
        model.now = Date()
        if model.selection >= model.items.count { model.selection = max(0, model.items.count - 1) }
    }

    // MARK: - Private

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470),
                             styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let view = HistoryView(model: model,
                               choose: { [weak self] index in self?.choose(index) },
                               queryChanged: { [weak self] in
                                   self?.model.selection = 0
                                   self?.reload()
                               })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    private func installMonitors(_ panel: NSPanel) {
        removeMonitors()
        // Local monitors run on the main thread.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        // Updates secret countdowns while open.
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.now = Date() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        clock?.invalidate()
        clock = nil
    }

    /// Returns true if the key was handled.
    private func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: hide(); return true                                    // esc
        case 125: move(1); return true                                   // ↓
        case 126: move(-1); return true                                  // ↑
        case 36, 76: choose(model.selection, paste: !event.modifierFlags.contains(.option)); return true  // ↩
        case 51 where cmd: act { self.gadget?.delete($0) }; return true  // ⌘⌫
        case 35 where cmd: act { self.gadget?.togglePin($0) }; return true  // ⌘P
        default: break
        }
        if cmd, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
            choose(digit - 1)
            return true
        }
        return false
    }

    private func move(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selection = min(max(0, model.selection + delta), model.items.count - 1)
    }

    private func act(_ f: (ClipItem) -> Void) {
        guard model.items.indices.contains(model.selection) else { return }
        f(model.items[model.selection])
    }

    /// ↩ copies (and pastes, if "paste directly" is on). ⌥↩ only copies.
    private func choose(_ index: Int, paste: Bool = true) {
        guard model.items.indices.contains(index), let gadget else { return }
        let item = model.items[index]
        hide()
        gadget.choose(item, paste: paste && gadget.model.settings.pasteDirectly)
    }
}
