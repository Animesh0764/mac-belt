import AppKit
import BeltKit
import Combine
import MicMuteCore
import SwiftUI

/// One shortcut mutes your microphone in every app (Zoom, Meet, Discord…), with a
/// "Muted" pill on screen so you always know. Replaces Mic Drop / MuteMe.
@MainActor
public final class MicMuteGadget: Gadget {
    public static let info = GadgetInfo(
        id: "mic-mute",
        name: "Mic Mute",
        symbol: "mic.slash",
        summary: "One shortcut mutes your mic in every app, with a big “Muted” sign so you always know.",
        replaces: "Mic Drop, MuteMe"
    )

    final class Model: ObservableObject {
        @Published var settings: MicMuteSettings
        @Published var hotkeyProblem: String?
        init(settings: MicMuteSettings) { self.settings = settings }
    }

    let model: Model
    private let context: GadgetContext
    private(set) var controller: MicController!
    private var watcher: MicWatcher?
    private var hotkey: HotkeyCenter.Registration?
    private var settingsSink: AnyCancellable?
    private let indicator = MutedIndicator()

    // Injected by tests (a fake mic, no Core Audio listeners).
    var deviceProvider: () -> MicDevice? = { CoreAudioMic.defaultInput() }
    var listensToCoreAudio = true

    public required init(context: GadgetContext) {
        self.context = context
        self.model = Model(settings: context.settings.load(MicMuteSettings.self, default: MicMuteSettings()))
    }

    var isMuted: Bool { controller?.muted ?? false }

    // MARK: - Lifecycle

    public func start() throws {
        controller = MicController(device: deviceProvider())
        if listensToCoreAudio {
            let watcher = MicWatcher(
                onDeviceChange: { [weak self] in MainActor.assumeIsolated { self?.defaultDeviceChanged() } },
                onStateChange: { [weak self] in MainActor.assumeIsolated { self?.deviceStateChanged() } })
            watcher.start()
            watcher.watch(device: (controller.device as? CoreAudioMic)?.id)
            self.watcher = watcher
        }
        settingsSink = model.$settings.dropFirst().sink { [weak self] new in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged(new) } }
        }
        indicator.onClick = { [weak self] in self?.setMuted(false) }
        registerHotkey()
        refreshUI()
    }

    public func stop() {
        // Off means off: never leave the mic muted with no sign on screen.
        controller?.restore()
        watcher?.stop()
        watcher = nil
        hotkey?.unregister()
        hotkey = nil
        settingsSink = nil
        indicator.hide()
        context.setBadge(nil)
    }

    // MARK: - Actions

    func toggle() { setMuted(!isMuted) }

    func setMuted(_ mute: Bool) {
        guard let controller else { return }
        do {
            try controller.setMuted(mute)
            context.toast(mute ? "Mic muted" : "Mic on", symbol: mute ? "mic.slash.fill" : "mic.fill")
            context.events.post(mute ? .micMuted : .micUnmuted, info: ["device": controller.device?.name ?? ""])
        } catch {
            context.toast(String(describing: error), symbol: "exclamationmark.triangle")
        }
        refreshUI()
    }

    func defaultDeviceChanged() {
        let wasMuted = isMuted
        controller.deviceChanged(to: deviceProvider())
        watcher?.watch(device: (controller.device as? CoreAudioMic)?.id)
        if wasMuted, isMuted, let name = controller.device?.name {
            context.toast("\(name) muted too", symbol: "mic.slash.fill")
        }
        refreshUI()
    }

    func deviceStateChanged() {
        let was = isMuted
        controller.syncFromDevice()
        if was != isMuted {
            context.events.post(isMuted ? .micMuted : .micUnmuted)
        }
        refreshUI()
    }

    private func refreshUI() {
        context.setBadge(isMuted ? "mic.slash.fill" : nil, priority: 10)
        if isMuted && model.settings.showIndicator {
            indicator.show(atTop: model.settings.indicatorAtTop)
        } else {
            indicator.hide()
        }
    }

    private func settingsChanged(_ new: MicMuteSettings) {
        context.settings.save(new)
        registerHotkey()
        refreshUI()
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
        case .success(let r): hotkey = r
        case .failure(.usedByGadget(let owner)): model.hotkeyProblem = "\(spec) is already used by \(owner)."
        case .failure(.rejectedBySystem): model.hotkeyProblem = "\(spec) is taken by another app."
        }
    }

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        let s = model.settings
        guard let device = controller?.device else {
            return [BeltMenuItem.label("No microphone found", symbol: "mic.slash")]
        }
        let state = isMuted ? "Muted" : "Mic on"
        var items: [NSMenuItem] = [
            BeltMenuItem.label("\(state) · \(device.name)", symbol: isMuted ? "mic.slash.fill" : "mic.fill"),
        ]
        let key = s.hotkeyEnabled ? HotkeySpec(s.hotkey).map { "   \($0)" } ?? "" : ""
        if isMuted {
            items.append(BeltMenuItem("Unmute\(key)", symbol: "mic.fill") { [weak self] in self?.setMuted(false) })
        } else {
            items.append(BeltMenuItem("Mute\(key)", symbol: "mic.slash.fill") { [weak self] in self?.setMuted(true) })
        }
        if !MicController.canMute(device) {
            items.append(BeltMenuItem.label("\(device.name) can't be muted"))
        }
        let options: [NSMenuItem] = [
            BeltMenuItem("Show “Muted” on screen", checked: s.showIndicator) { [weak self] in
                self?.model.settings.showIndicator.toggle()
            },
            BeltMenuItem("At the top of the screen", checked: s.indicatorAtTop, enabled: s.showIndicator) { [weak self] in
                self?.model.settings.indicatorAtTop = true
            },
            BeltMenuItem("At the bottom of the screen", checked: !s.indicatorAtTop, enabled: s.showIndicator) { [weak self] in
                self?.model.settings.indicatorAtTop = false
            },
        ]
        items.append(BeltMenuItem("Options", symbol: "slider.horizontal.3", submenu: options))
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(MicMuteSettingsView(model: model))
    }
}

struct MicMuteSettingsView: View {
    @ObservedObject var model: MicMuteGadget.Model

    var body: some View {
        Form {
            Section("Shortcut") {
                Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled)
                if model.settings.hotkeyEnabled {
                    TextField("Shortcut", text: $model.settings.hotkey, prompt: Text("ctrl+opt+m"))
                    if let problem = model.hotkeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let spec = HotkeySpec(model.settings.hotkey) {
                        Text("Press \(spec.description) to mute or unmute, in any app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("While muted") {
                Toggle("Show “Muted” on screen", isOn: $model.settings.showIndicator)
                Picker("Position", selection: $model.settings.indicatorAtTop) {
                    Text("Top").tag(true)
                    Text("Bottom").tag(false)
                }
                .disabled(!model.settings.showIndicator)
                Text("Click the sign to unmute. The menu bar icon also turns into a crossed-out mic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Mutes the microphone itself, so it works in every app. Switching mics (e.g. AirPods connecting) keeps you muted. Turning this gadget off or quitting Mac Belt unmutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
