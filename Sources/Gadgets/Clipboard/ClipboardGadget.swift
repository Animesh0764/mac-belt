import AppKit
import BeltKit
import ClipboardCore
import Combine
import SwiftUI

/// Clipboard history you can search, where OTPs, API keys and passwords remove themselves
/// after 60 s: from the history AND from the clipboard. Secrets never touch the disk.
@MainActor
public final class ClipboardGadget: Gadget {
    public static let info = GadgetInfo(
        id: "clipboard",
        name: "Clipboard",
        symbol: "doc.on.clipboard",
        summary: "Searchable clipboard history. OTPs, API keys and passwords wipe themselves after 60 seconds.",
        replaces: "Paste, Maccy",
        permissions: [.pasteboard]
    )

    final class Model: ObservableObject {
        @Published var settings: ClipboardSettings
        @Published var hotkeyProblem: String?
        @Published var paused = false
        @Published var pausedForPresentation = false
        @Published var itemCount = 0
        init(settings: ClipboardSettings) { self.settings = settings }
    }

    let model: Model
    private let context: GadgetContext
    let pasteboard: NSPasteboard
    private let storeURL: URL
    private(set) var store: ClipStore?
    private(set) var shelf = SecretShelf()

    private var lastChangeCount = 0
    /// Change count right after Mac Belt itself wrote to the pasteboard (not a new copy).
    private var ownWriteChangeCount = -1
    /// Secret id → pasteboard change count when it was on the clipboard.
    private var secretChangeCounts: [Int64: Int] = [:]

    private var timer: Timer?
    private var hotkey: HotkeyCenter.Registration?
    private var subscriptions: [EventBus.Subscription] = []
    private var settingsSink: AnyCancellable?
    private var lastPrune = Date.distantPast
    private lazy var panel = HistoryPanel(gadget: self)

    // Injected by tests.
    var now: () -> Date = Date.init
    var frontmostApp: () -> AppRef? = {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return AppRef(bundleID: id, name: app.localizedName ?? id)
    }
    var pasteHandler: () -> Bool = Paster.pasteIntoFrontmostApp

    public required convenience init(context: GadgetContext) {
        self.init(context: context, pasteboard: .general)
    }

    init(context: GadgetContext, pasteboard: NSPasteboard) {
        self.context = context
        self.pasteboard = pasteboard
        self.storeURL = context.settings.store.directory.appendingPathComponent("clipboard.sqlite")
        self.model = Model(settings: context.settings.load(ClipboardSettings.self, default: ClipboardSettings()))
    }

    // MARK: - Lifecycle

    public func start() throws {
        do {
            store = try ClipStore(url: storeURL)
        } catch {
            throw GadgetError("Couldn't open the clipboard history: \(error)")
        }
        // Don't record whatever is already on the clipboard; only new copies.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        subscriptions = [
            context.events.on(.presentationStarted) { [weak self] _ in self?.model.pausedForPresentation = true },
            context.events.on(.presentationEnded) { [weak self] _ in self?.model.pausedForPresentation = false },
        ]
        settingsSink = model.$settings.dropFirst().sink { [weak self] new in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged(new) } }
        }
        registerHotkey()
        prune()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        hotkey?.unregister()
        hotkey = nil
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        settingsSink = nil
        panel.hide()
        // Secrets never outlive the gadget: wipe one still on the clipboard.
        if model.settings.wipeClipboard {
            for item in shelf.items where secretChangeCounts[item.id] == pasteboard.changeCount {
                pasteboard.clearContents()
            }
        }
        shelf.removeAll()
        secretChangeCounts.removeAll()
        store = nil
    }

    // MARK: - Core loop

    func tick() {
        poll()
        expireSecrets()
    }

    /// Records a new copy, if there is one.
    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard count != ownWriteChangeCount else { return }
        guard !model.paused, !model.pausedForPresentation else { return }
        if pasteboard == NSPasteboard.general, accessState == .denied { return }
        if ClipboardRules.shouldIgnore(types: PasteboardIO.types(pasteboard)) { return }
        let source = frontmostApp()
        if let source, model.settings.ignoredApps.contains(where: { $0.bundleID == source.bundleID }) { return }
        guard let content = PasteboardIO.read(pasteboard, storeImages: model.settings.storeImages) else { return }
        record(content, source: source, changeCount: count)
    }

    private func record(_ content: ClipContent, source: AppRef?, changeCount: Int) {
        let now = now()
        if model.settings.detectSecrets, case .text(let text) = content, let match = SecretDetector.detect(text) {
            let item = shelf.add(content, secret: match, source: source, now: now,
                                 lifetime: TimeInterval(model.settings.secretSeconds))
            secretChangeCounts[item.id] = changeCount
            if model.settings.showSecretToast {
                context.toast("\(match.label) · removed in \(model.settings.secretSeconds) s", symbol: "lock.fill")
            }
        } else {
            do {
                try store?.add(content, source: source, at: now)
            } catch {
                context.log.error("couldn't save clipboard item: \(String(describing: error))")
            }
            if now.timeIntervalSince(lastPrune) > 3600 { prune() }
        }
        refreshCount()
        panel.reload()
    }

    /// Removes expired secrets, and clears the clipboard if it still holds one.
    func expireSecrets() {
        let expired = shelf.expire(now: now())
        guard !expired.isEmpty else { return }
        var wiped = false
        for item in expired {
            if model.settings.wipeClipboard, secretChangeCounts[item.id] == pasteboard.changeCount {
                pasteboard.clearContents()
                lastChangeCount = pasteboard.changeCount
                wiped = true
            }
            secretChangeCounts[item.id] = nil
        }
        if wiped && model.settings.showSecretToast {
            context.toast("Secret wiped from the clipboard", symbol: "lock.slash.fill")
        }
        panel.reload()
    }

    func prune() {
        lastPrune = now()
        let s = model.settings
        let cutoff = s.keepDays.map { now().addingTimeInterval(-Double($0) * 86_400) }
        _ = try? store?.prune(limit: s.historyLimit, olderThan: cutoff)
        refreshCount()
    }

    private func refreshCount() {
        model.itemCount = ((try? store?.count()) ?? 0) + shelf.items.count
    }

    // MARK: - Reading history (for the panel and the menu)

    /// Pinned first, then everything else newest first. Secrets are mixed in by time.
    func history(matching query: String = "", limit: Int = 300) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = (try? store?.items(matching: q.isEmpty ? nil : q, limit: limit)) ?? []
        // Secrets are matched by their label only, never by their content.
        let secrets = shelf.items.filter { q.isEmpty || $0.secret!.label.localizedCaseInsensitiveContains(q) }
        let pinned = saved.filter(\.pinned)
        let rest = (saved.filter { !$0.pinned } + secrets).sorted { $0.lastUsedAt > $1.lastUsedAt }
        return Array((pinned + rest).prefix(limit))
    }

    // MARK: - Actions

    /// Puts an item on the clipboard (and pastes it if that's switched on).
    func choose(_ item: ClipItem, paste: Bool? = nil) {
        let count = PasteboardIO.write(item.content, to: pasteboard)
        ownWriteChangeCount = count
        lastChangeCount = count
        let now = now()
        if item.isSecret {
            shelf.refresh(item.id, now: now, lifetime: TimeInterval(model.settings.secretSeconds))
            secretChangeCounts[item.id] = count
        } else {
            try? store?.touch(item.id, at: now)
        }
        if paste ?? model.settings.pasteDirectly {
            // Let the panel close and focus return to the previous app first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.pasteHandler() else { return }
                    self.context.toast("Copied. Allow Accessibility to paste directly", symbol: "doc.on.clipboard")
                }
            }
        } else {
            context.toast("Copied", symbol: "doc.on.clipboard")
        }
    }

    func delete(_ item: ClipItem) {
        if item.isSecret {
            shelf.remove(item.id)
            secretChangeCounts[item.id] = nil
        } else {
            try? store?.delete(item.id)
        }
        refreshCount()
        panel.reload()
    }

    func togglePin(_ item: ClipItem) {
        guard !item.isSecret else { return }  // secrets can't be pinned: they'd never expire
        try? store?.setPinned(item.id, !item.pinned)
        panel.reload()
    }

    func clearHistory() {
        try? store?.clear(keepPinned: true)
        shelf.removeAll()
        secretChangeCounts.removeAll()
        refreshCount()
        panel.reload()
        context.toast("History cleared (pinned items kept)", symbol: "trash")
    }

    func isIgnored(_ bundleID: String) -> Bool {
        model.settings.ignoredApps.contains { $0.bundleID == bundleID }
    }

    func ignore(_ app: AppRef) {
        guard !isIgnored(app.bundleID) else { return }
        model.settings.ignoredApps.append(app)
        context.toast("Copies from \(app.name) won't be saved", symbol: "eye.slash")
    }

    func unignore(_ app: AppRef) {
        guard isIgnored(app.bundleID) else { return }
        model.settings.ignoredApps.removeAll { $0.bundleID == app.bundleID }
        context.toast("Copies from \(app.name) will be saved again", symbol: "eye")
    }

    func setPaused(_ paused: Bool) {
        model.paused = paused
        context.toast(paused ? "History paused · new copies won't be saved" : "History resumed",
                      symbol: paused ? "pause.fill" : "play.fill")
    }

    /// Is this app on the Mac? (Ignored apps that aren't installed are hidden from the menu.)
    var isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    /// Regular (Dock) apps running now, excluding Mac Belt.
    var runningApps: () -> [AppRef] = {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { AppRef(bundleID: $0, name: app.localizedName ?? $0) } }
    }

    func showHistory() { panel.toggle() }

    private func settingsChanged(_ new: ClipboardSettings) {
        context.settings.save(new)
        registerHotkey()
        prune()
        panel.reload()
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
        switch context.hotkeys.register(spec, owner: Self.info.name, handler: { [weak self] in self?.showHistory() }) {
        case .success(let r): hotkey = r
        case .failure(.usedByGadget(let owner)): model.hotkeyProblem = "\(spec) is already used by \(owner)."
        case .failure(.rejectedBySystem): model.hotkeyProblem = "\(spec) is taken by another app."
        }
    }

    // MARK: - Paste-from-other-apps setting (macOS 15.4+)

    enum AccessState { case allowed, asks, denied }

    var accessState: AccessState {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        default: return .asks
        }
    }

    static let accessHelp = "System Settings ▸ Privacy & Security ▸ Paste from Other Apps ▸ Mac Belt ▸ Allow"

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let s = model.settings
        switch accessState {
        case .denied:
            items.append(BeltMenuItem("Not allowed to read the clipboard…", symbol: "exclamationmark.triangle") { [weak self] in
                self?.context.permissions.openSettings(.pasteboard)
            })
        case .asks:
            items.append(BeltMenuItem("macOS asks before each copy. Fix…", symbol: "exclamationmark.triangle") { [weak self] in
                self?.context.toast(Self.accessHelp)
                self?.context.permissions.openSettings(.pasteboard)
            })
        case .allowed:
            break
        }
        var status = model.itemCount == 1 ? "1 item saved" : "\(model.itemCount) items saved"
        if model.pausedForPresentation { status += " · paused while presenting" } else if model.paused { status += " · paused" }
        items.append(BeltMenuItem.label(status, symbol: model.paused || model.pausedForPresentation ? "pause.circle" : nil))

        let key = s.hotkeyEnabled ? HotkeySpec(s.hotkey).map { "   \($0)" } ?? "" : ""
        items.append(BeltMenuItem("Open History\(key)", symbol: "magnifyingglass") { [weak self] in self?.showHistory() })

        let recent = history().prefix(5)
        if !recent.isEmpty {
            let recentItems: [NSMenuItem] = recent.map { item in
                let title = String(item.displayText.prefix(48))
                return BeltMenuItem(title, symbol: item.isSecret ? "lock.fill" : nil) { [weak self] in
                    self?.choose(item, paste: false)
                }
            }
            items.append(BeltMenuItem("Recent", symbol: "clock", submenu: recentItems))
        }

        let paused = model.paused
        items.append(BeltMenuItem(paused ? "Resume Saving History" : "Pause Saving History",
                                  symbol: paused ? "play.fill" : "pause.fill") { [weak self] in
            self?.setPaused(!paused)
        })

        // Tick = copies from that app aren't saved. Click to toggle.
        // Lists ignored apps that are installed, plus apps that are running now.
        var apps: [AppRef] = model.settings.ignoredApps.filter { isInstalled($0.bundleID) }
        for app in runningApps() where !apps.contains(where: { $0.bundleID == app.bundleID }) {
            apps.append(app)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var ignoredItems: [NSMenuItem] = [BeltMenuItem.label("Don't save copies from")]
        ignoredItems += apps.map { app in
            let ignored = isIgnored(app.bundleID)
            let item = BeltMenuItem(app.name, checked: ignored) { [weak self] in
                ignored ? self?.unignore(app) : self?.ignore(app)
            }
            if let icon = AppIcons.icon(app.bundleID)?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            return item
        }
        items.append(BeltMenuItem("Ignored Apps", symbol: "eye.slash", submenu: ignoredItems))
        items.append(BeltMenuItem("Clear History", symbol: "trash") { [weak self] in self?.clearHistory() })
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(ClipboardSettingsView(model: model,
                                      requestAccessibility: { [weak self] in self?.context.permissions.request(.accessibility) },
                                      openPasteSettings: { [weak self] in self?.context.permissions.openSettings(.pasteboard) },
                                      clear: { [weak self] in self?.clearHistory() }))
    }
}
