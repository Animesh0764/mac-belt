import AppKit
import AwakeCore
import BeltKit
import Combine
import SwiftUI

/// Keep the Mac (and screen) awake: for a while, until turned off, while chosen apps run,
/// optionally only on power. Replaces Amphetamine / Lungo / Caffeine.
@MainActor
public final class AwakeGadget: Gadget {
    public static let info = GadgetInfo(
        id: "awake",
        name: "Awake",
        symbol: "sun.max",
        summary: "Keep your Mac awake for a while, until you say stop, or while an app is running.",
        replaces: "Amphetamine, Lungo"
    )

    /// Settings the menu and the Settings page both edit.
    final class Model: ObservableObject {
        @Published var settings: AwakeSettings
        @Published var hotkeyProblem: String?
        init(settings: AwakeSettings) { self.settings = settings }
    }

    let model: Model
    private let context: GadgetContext
    private let assertion = PowerAssertion(name: "Mac Belt · Awake")
    private(set) var session: AwakeSession?
    private(set) var reason: AwakeReason?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settingsSink: AnyCancellable?
    private var hotkey: HotkeyCenter.Registration?
    /// Tests inject these.
    var now: () -> Date = Date.init
    var isOnPower: () -> Bool = PowerSource.isOnAC
    var runningBundleIDs: () -> Set<String> = {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public required init(context: GadgetContext) {
        self.context = context
        self.model = Model(settings: context.settings.load(AwakeSettings.self, default: AwakeSettings()))
    }

    var isHoldingAssertion: Bool { assertion.isHeld }

    // MARK: - Lifecycle

    public func start() throws {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        // Checks timers, power source, and apps every 15 s. Cheap: no work unless state changes.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        settingsSink = model.$settings.dropFirst().sink { [weak self] new in
            // @Published fires before the value is stored; act on the new value next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged(new) } }
        }
        registerHotkey()
        evaluate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        settingsSink = nil
        hotkey?.unregister()
        hotkey = nil
        session = nil
        assertion.release()
        if reason != nil { context.events.post(.awakeEnded) }
        reason = nil
        context.setBadge(nil)
    }

    // MARK: - Actions

    func turnOn(minutes: Int?) {
        session = AwakeLogic.session(minutes: minutes, now: now())
        evaluate()
        context.toast("Awake · \(AwakeLogic.durationLabel(minutes: minutes).lowercased())", symbol: "sun.max.fill")
    }

    func turnOff() {
        session = nil
        evaluate()
        if case .app(let name) = reason {
            context.toast("Still awake while \(name) is running", symbol: "sun.max.fill")
        } else {
            context.toast("Awake off", symbol: "moon.zzz")
        }
    }

    func toggle() {
        if session != nil { turnOff() } else { turnOn(minutes: model.settings.defaultMinutes) }
    }

    func addWatchedApp(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, !model.settings.watchedApps.contains(where: { $0.bundleID == id }) else { return }
        model.settings.watchedApps.append(WatchedApp(bundleID: id, name: app.localizedName ?? id))
    }

    func removeWatchedApp(_ bundleID: String) {
        model.settings.watchedApps.removeAll { $0.bundleID == bundleID }
    }

    // MARK: - Core loop

    /// Recompute whether to hold the assertion. Safe to call any time.
    func evaluate() {
        let now = now()
        if let s = session, AwakeLogic.isExpired(s, now: now) {
            session = nil
            context.toast("Awake ended", symbol: "moon.zzz")
        }
        let running = runningBundleIDs()
        let watched = model.settings.watchedApps.filter { running.contains($0.bundleID) }
        let newReason = AwakeLogic.decide(session: session, runningWatchedApps: watched,
                                          onPower: isOnPower(), settings: model.settings, now: now)
        if newReason != nil {
            assertion.hold(model.settings.keepDisplayOn ? .display : .system)
        } else {
            assertion.release()
        }
        if (reason == nil) != (newReason == nil) {
            context.events.post(newReason == nil ? .awakeEnded : .awakeStarted,
                                info: ["reason": AwakeLogic.statusText(newReason, now: now)])
        }
        reason = newReason
        context.setBadge(newReason == nil ? nil : "sun.max.fill")
    }

    private func settingsChanged(_ new: AwakeSettings) {
        context.settings.save(new)
        registerHotkey()
        evaluate()
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
        switch context.hotkeys.register(spec, owner: Self.info.name, handler: { [weak self] in self?.toggle() }) {
        case .success(let registration):
            hotkey = registration
        case .failure(.usedByGadget(let owner)):
            model.hotkeyProblem = "\(spec) is already used by \(owner)."
        case .failure(.rejectedBySystem):
            model.hotkeyProblem = "\(spec) is taken by another app."
        }
    }

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        let s = model.settings
        let on = reason != nil
        // Status line: ☀ when awake, ☾ when not.
        var items: [NSMenuItem] = [
            BeltMenuItem.label(AwakeLogic.statusText(reason, now: now()), symbol: on ? "sun.max.fill" : "moon.fill"),
        ]

        if session != nil {
            items.append(BeltMenuItem("Turn Off", symbol: "moon.fill") { [weak self] in self?.turnOff() })
        } else {
            items.append(BeltMenuItem("Turn On", symbol: "sun.max.fill") { [weak self] in
                self?.turnOn(minutes: self?.model.settings.defaultMinutes)
            })
        }

        // One list of durations; the running one is ticked. Picking one (re)starts the timer.
        let choices: [Int?] = [nil] + AwakeLogic.durationChoices.map { Optional($0) }
        let durations = choices.map { minutes in
            BeltMenuItem(AwakeLogic.durationLabel(minutes: minutes),
                         checked: session != nil && session?.minutes == minutes) { [weak self] in
                self?.turnOn(minutes: minutes)
            }
        }
        items.append(BeltMenuItem("Keep Awake For", symbol: "timer", submenu: durations))

        // Apps that keep the Mac awake while running (ticked = watched; click to remove).
        var appItems: [NSMenuItem] = s.watchedApps.map { app in
            BeltMenuItem(app.name, checked: true) { [weak self] in self?.removeWatchedApp(app.bundleID) }
        }
        if !appItems.isEmpty {
            appItems.append(BeltMenuItem.label("Click an app to stop watching it"))
            appItems.append(.separator())
        }
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in !s.watchedApps.contains { $0.bundleID == app.bundleIdentifier } }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let addItems: [NSMenuItem] = candidates.map { app in
            let item = BeltMenuItem(app.localizedName ?? app.bundleIdentifier ?? "App") { [weak self] in
                self?.addWatchedApp(app)
            }
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            return item
        }
        appItems.append(BeltMenuItem("Add an App", symbol: "plus", submenu: addItems))
        items.append(BeltMenuItem("Stay Awake While App Runs", symbol: "app.badge.checkmark", submenu: appItems))

        // Options live in their own submenu so their ticks aren't confused with "is it on".
        let options: [NSMenuItem] = [
            BeltMenuItem("Keep the screen on too", checked: s.keepDisplayOn) { [weak self] in
                self?.model.settings.keepDisplayOn.toggle()
            },
            BeltMenuItem.label("Off: screen can sleep, Mac keeps running"),
            .separator(),
            BeltMenuItem("Only when plugged in", checked: s.onlyOnPower) { [weak self] in
                self?.model.settings.onlyOnPower.toggle()
            },
        ]
        items.append(BeltMenuItem("Options", symbol: "slider.horizontal.3", submenu: options))
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(AwakeSettingsView(model: model, remove: { [weak self] id in self?.removeWatchedApp(id) }))
    }
}

struct AwakeSettingsView: View {
    @ObservedObject var model: AwakeGadget.Model
    let remove: (String) -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Keep the screen on", isOn: $model.settings.keepDisplayOn)
                Text("Off: the screen can sleep, but the Mac keeps running (downloads, builds, music).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Only while on power", isOn: $model.settings.onlyOnPower)
            }
            Section("“Turn On” and the shortcut keep it awake") {
                Picker("For", selection: $model.settings.defaultMinutes) {
                    Text(AwakeLogic.durationLabel(minutes: nil)).tag(Int?.none)
                    ForEach(AwakeLogic.durationChoices, id: \.self) { m in
                        Text(AwakeLogic.durationLabel(minutes: m)).tag(Int?.some(m))
                    }
                }
                Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled)
                if model.settings.hotkeyEnabled {
                    TextField("Shortcut", text: $model.settings.hotkey, prompt: Text("ctrl+opt+cmd+a"))
                    if let problem = model.hotkeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let spec = HotkeySpec(model.settings.hotkey) {
                        Text("Press \(spec.description) to turn Awake on or off.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Stay awake while these apps run") {
                if model.settings.watchedApps.isEmpty {
                    Text("None yet. Add apps from the menu: Awake ▸ While App Runs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.settings.watchedApps, id: \.bundleID) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Button("Remove") { remove(app.bundleID) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
