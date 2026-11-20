import AppKit
import BeltKit
import Combine
import ShelfCore
import SwiftUI

/// Shake the cursor while dragging files, and a shelf appears to park them on.
/// Drag them out again wherever you want. Replaces Dropover / Yoink.
@MainActor
public final class ShelfGadget: Gadget {
    public static let info = GadgetInfo(
        id: "shelf",
        name: "Drop Shelf",
        symbol: "tray.and.arrow.down",
        summary: "Shake the cursor while dragging files and a shelf appears. Park files there, drag them out later.",
        replaces: "Dropover, Yoink"
    )

    final class Model: ObservableObject {
        @Published var settings: ShelfSettings
        @Published var shelf = Shelf()
        @Published var hotkeyProblem: String?
        init(settings: ShelfSettings) { self.settings = settings }
    }

    let model: Model
    private let context: GadgetContext
    private var tracker = DragShakeTracker()
    private var timer: Timer?
    private var fastMode = false
    private var hotkey: HotkeyCenter.Registration?
    private var settingsSink: AnyCancellable?
    private lazy var panel = ShelfPanel(model: model, gadget: self)

    // Injected by tests.
    var mouseButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    var mouseX: () -> Double = { Double(NSEvent.mouseLocation.x) }
    var dragChangeCount: () -> Int = { NSPasteboard(name: .drag).changeCount }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var presentsPanel = true

    public required init(context: GadgetContext) {
        self.context = context
        self.model = Model(settings: context.settings.load(ShelfSettings.self, default: ShelfSettings()))
    }

    private(set) var isShelfShown = false

    // MARK: - Lifecycle

    public func start() throws {
        settingsSink = model.$settings.dropFirst().sink { [weak self] new in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged(new) } }
        }
        registerHotkey()
        updateWatching()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        hotkey?.unregister()
        hotkey = nil
        settingsSink = nil
        hideShelf()
        model.shelf.removeAll()
    }

    // MARK: - Watching for a shake

    /// Idle: 5 checks a second for "mouse button down". While it's down: 60 a second.
    private func updateWatching() {
        timer?.invalidate()
        timer = nil
        guard model.settings.shakeToOpen else { return }
        schedule(interval: 0.2)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
        fastMode = interval < 0.1
    }

    func tick() {
        let down = mouseButtonDown()
        if tracker.tick(buttonDown: down, x: mouseX(), dragChangeCount: dragChangeCount(), at: clock()) {
            showShelf(nearCursor: true)
        }
        if timer != nil {
            if down && !fastMode { schedule(interval: 1.0 / 60) }
            if !down && fastMode { schedule(interval: 0.2) }
        }
    }

    // MARK: - Shelf

    func showShelf(nearCursor: Bool = false) {
        model.shelf.pruneMissing()
        isShelfShown = true
        if presentsPanel { panel.show(nearCursor: nearCursor) }
    }

    func hideShelf() {
        isShelfShown = false
        if presentsPanel { panel.hide() }
    }

    func toggleShelf() { isShelfShown ? hideShelf() : showShelf() }

    func add(_ urls: [URL]) {
        model.shelf.add(urls)
    }

    func remove(_ url: URL) {
        model.shelf.remove(url)
    }

    /// The ✕ button: empty the shelf and put it away.
    func clearAndClose() {
        model.shelf.removeAll()
        hideShelf()
    }

    private func settingsChanged(_ new: ShelfSettings) {
        context.settings.save(new)
        registerHotkey()
        updateWatching()
    }

    private func registerHotkey() {
        hotkey?.unregister()
        hotkey = nil
        model.hotkeyProblem = nil
        guard model.settings.hotkeyEnabled else { return }
        guard let spec = HotkeySpec(model.settings.hotkey) else {
            model.hotkeyProblem = "“\(model.settings.hotkey)” isn't a valid shortcut."
            return
        }
        switch context.hotkeys.register(spec, owner: Self.info.name, handler: { [weak self] in self?.toggleShelf() }) {
        case .success(let r): hotkey = r
        case .failure(.usedByGadget(let owner)): model.hotkeyProblem = "\(spec) is already used by \(owner)."
        case .failure(.rejectedBySystem): model.hotkeyProblem = "\(spec) is taken by another app."
        }
    }

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        let s = model.settings
        var items: [NSMenuItem] = [BeltMenuItem.label("Shelf · \(model.shelf.summary)", symbol: "tray")]
        let key = s.hotkeyEnabled ? HotkeySpec(s.hotkey).map { "   \($0)" } ?? "" : ""
        if isShelfShown {
            items.append(BeltMenuItem("Hide Shelf\(key)", symbol: "tray.and.arrow.up") { [weak self] in self?.hideShelf() })
        } else {
            items.append(BeltMenuItem("Show Shelf\(key)", symbol: "tray.and.arrow.down") { [weak self] in self?.showShelf() })
        }
        if !model.shelf.items.isEmpty {
            items.append(BeltMenuItem("Empty Shelf", symbol: "trash") { [weak self] in self?.model.shelf.removeAll() })
        }
        items.append(BeltMenuItem("Shake While Dragging to Open", checked: s.shakeToOpen) { [weak self] in
            self?.model.settings.shakeToOpen.toggle()
        })
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(ShelfSettingsView(model: model))
    }
}

struct ShelfSettingsView: View {
    @ObservedObject var model: ShelfGadget.Model

    var body: some View {
        Form {
            Section {
                Toggle("Shake the cursor while dragging to open the shelf", isOn: $model.settings.shakeToOpen)
                Text("Drag a file, wiggle the mouse left-right a few times, and the shelf pops up next to the cursor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled)
                if model.settings.hotkeyEnabled {
                    TextField("Shortcut", text: $model.settings.hotkey, prompt: Text("ctrl+opt+s"))
                    if let problem = model.hotkeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let spec = HotkeySpec(model.settings.hotkey) {
                        Text("Press \(spec.description) to show or hide the shelf.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("The shelf holds references, not copies. Dragging a file out to another folder on the same disk moves it, like in Finder (hold ⌥ to copy). The ✕ button empties the shelf; your files stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
