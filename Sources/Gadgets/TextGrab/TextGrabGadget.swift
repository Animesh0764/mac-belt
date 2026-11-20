import AppKit
import BeltKit
import Combine
import SwiftUI
import TextGrabCore

/// Drag a box anywhere on screen and the text inside it is on your clipboard.
/// Works on images, videos, PDFs, error dialogs, screen shares. On-device OCR.
/// Replaces TextSniper.
@MainActor
public final class TextGrabGadget: Gadget {
    public static let info = GadgetInfo(
        id: "text-grab",
        name: "Text Grab",
        symbol: "text.viewfinder",
        summary: "Drag a box over any text on screen, even in images or videos, and it's copied. Reads QR codes too.",
        replaces: "TextSniper",
        permissions: [.screenRecording]
    )

    final class Model: ObservableObject {
        @Published var settings: TextGrabSettings
        @Published var hotkeyProblem: String?
        init(settings: TextGrabSettings) { self.settings = settings }
    }

    let model: Model
    private let context: GadgetContext
    private var hotkey: HotkeyCenter.Registration?
    private var settingsSink: AnyCancellable?
    private var askedForPermission = false
    private(set) var isGrabbing = false
    private var running = false

    // Injected by tests (no screen, no clipboard).
    var capturer: RegionCapturer = FreezeFramePicker()
    var recognizer: TextRecognizer = VisionRecognizer()
    var hasPermission: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt (first time) or opens System Settings.
    lazy var openPermission: (_ firstTime: Bool) -> Void = { [weak self] first in
        guard let self else { return }
        if first { self.context.permissions.request(.screenRecording) }
        else { self.context.permissions.openSettings(.screenRecording) }
    }
    var copy: (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// What the last grab showed in its toast (for tests and the menu).
    private(set) var lastMessage: String?

    public required init(context: GadgetContext) {
        self.context = context
        self.model = Model(settings: context.settings.load(TextGrabSettings.self, default: TextGrabSettings()))
    }

    // MARK: - Lifecycle

    public func start() throws {
        running = true
        settingsSink = model.$settings.dropFirst().sink { [weak self] new in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChanged(new) } }
        }
        registerHotkey()
    }

    public func stop() {
        running = false
        hotkey?.unregister()
        hotkey = nil
        settingsSink = nil
    }

    // MARK: - Grab

    func grab() {
        Task { await grabNow() }
    }

    func grabNow() async {
        guard running, !isGrabbing else { return }
        guard hasPermission() else {
            askForPermission()
            return
        }
        isGrabbing = true
        defer { isGrabbing = false }

        let s = model.settings
        do {
            guard let image = try await capturer.capture() else { return }  // Esc: say nothing
            let result = try await recognizer.recognize(image, readCodes: s.readCodes)
            let text = TextLayout.text(from: result.lines, keepLineBreaks: s.keepLineBreaks)
            let message = TextLayout.summary(text: text, codes: result.codes)
            let clip = TextLayout.clipboardText(text: text, codes: result.codes)
            if clip.isEmpty {
                show(message, symbol: "text.magnifyingglass")
            } else {
                copy(clip)
                show("\(message) · press ⌘V to paste\n“\(TextLayout.preview(clip))”", symbol: "doc.on.clipboard",
                     duration: 3.5)
            }
        } catch CaptureError.notAllowed {
            askForPermission()
        } catch {
            show("Couldn't read that: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    private func askForPermission() {
        if !askedForPermission {
            askedForPermission = true
            openPermission(true)
            show("Allow Mac Belt under Screen Recording, then try again", symbol: "lock")
        } else {
            openPermission(false)
            show("Turn on Mac Belt under Screen Recording. Already on? Quit and reopen Mac Belt.", symbol: "lock")
        }
    }

    private func show(_ message: String, symbol: String, duration: TimeInterval = 2.2) {
        lastMessage = message
        context.toast(message, symbol: symbol, duration: duration)
    }

    // MARK: - Settings

    private func settingsChanged(_ new: TextGrabSettings) {
        context.settings.save(new)
        registerHotkey()
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
        switch context.hotkeys.register(spec, owner: Self.info.name, handler: { [weak self] in self?.grab() }) {
        case .success(let r): hotkey = r
        case .failure(.usedByGadget(let owner)): model.hotkeyProblem = "\(spec) is already used by \(owner)."
        case .failure(.rejectedBySystem): model.hotkeyProblem = "\(spec) is taken by another app."
        }
    }

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        let s = model.settings
        let key = s.hotkeyEnabled ? HotkeySpec(s.hotkey).map { "   \($0)" } ?? "" : ""
        var items: [NSMenuItem] = []
        if !hasPermission() {
            items.append(BeltMenuItem("Needs Screen Recording: Allow…", symbol: "lock") { [weak self] in
                self?.context.permissions.openSettings(.screenRecording)
            })
        }
        items.append(BeltMenuItem("Grab Text…\(key)", symbol: "text.viewfinder") { [weak self] in
            // Let the menu close first so it isn't in the screenshot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.grab() }
        })
        let options: [NSMenuItem] = [
            BeltMenuItem("Keep line breaks", checked: s.keepLineBreaks) { [weak self] in
                self?.model.settings.keepLineBreaks.toggle()
            },
            BeltMenuItem.label("Off: each paragraph is copied as one line"),
            NSMenuItem.separator(),
            BeltMenuItem("Read QR codes and barcodes", checked: s.readCodes) { [weak self] in
                self?.model.settings.readCodes.toggle()
            },
        ]
        items.append(BeltMenuItem("Options", symbol: "slider.horizontal.3", submenu: options))
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(TextGrabSettingsView(model: model))
    }
}

struct TextGrabSettingsView: View {
    @ObservedObject var model: TextGrabGadget.Model

    var body: some View {
        Form {
            Section("Shortcut") {
                Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled)
                if model.settings.hotkeyEnabled {
                    TextField("Shortcut", text: $model.settings.hotkey, prompt: Text("ctrl+opt+t"))
                    if let problem = model.hotkeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let spec = HotkeySpec(model.settings.hotkey) {
                        Text("Press \(spec.description): the screen freezes, then drag a box over the text. Esc cancels.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Text") {
                Toggle("Keep line breaks", isOn: $model.settings.keepLineBreaks)
                Text("Off joins each paragraph into one line, which is handy for text from PDFs and slides.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Read QR codes and barcodes", isOn: $model.settings.readCodes)
            }
            Section {
                Text("Text is read on your Mac by Apple's built-in text recognition. The frozen screenshot is kept in memory only, never saved, and nothing is uploaded. macOS needs the Screen Recording permission for Mac Belt to see what's on screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
