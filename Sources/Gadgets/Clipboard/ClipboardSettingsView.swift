import BeltKit
import ClipboardCore
import SwiftUI

struct ClipboardSettingsView: View {
    @ObservedObject var model: ClipboardGadget.Model
    let requestAccessibility: () -> Void
    let openPasteSettings: () -> Void
    let clear: () -> Void

    var body: some View {
        Form {
            Section {
                Text("macOS asks before an app reads the clipboard in the background. For history to work, set Mac Belt to **Allow** in System Settings ▸ Privacy & Security ▸ Paste from Other Apps. (It appears there after the first prompt.)")
                    .font(.callout)
                Button("Open Privacy & Security", action: openPasteSettings)
            }
            Section("Secrets") {
                Toggle("Detect OTPs, API keys, tokens and passwords", isOn: $model.settings.detectSecrets)
                Picker("Remove them after", selection: $model.settings.secretSeconds) {
                    ForEach([15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                .disabled(!model.settings.detectSecrets)
                Toggle("Also wipe them from the clipboard", isOn: $model.settings.wipeClipboard)
                    .disabled(!model.settings.detectSecrets)
                Toggle("Show a notice when a secret is copied", isOn: $model.settings.showSecretToast)
                    .disabled(!model.settings.detectSecrets)
                Text("Secrets are kept in memory only and are never written to disk. Copies from password managers are never saved at all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Picker("Keep up to", selection: $model.settings.historyLimit) {
                    ForEach([50, 100, 300, 1000], id: \.self) { Text("\($0) items").tag($0) }
                }
                Picker("For", selection: $model.settings.keepDays) {
                    Text("1 day").tag(Int?.some(1))
                    Text("7 days").tag(Int?.some(7))
                    Text("30 days").tag(Int?.some(30))
                    Text("90 days").tag(Int?.some(90))
                    Text("Forever").tag(Int?.none)
                }
                Toggle("Keep images", isOn: $model.settings.storeImages)
                Text("Pinned items are kept forever. History is stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear History (keeps pinned)", role: .destructive, action: clear)
            }
            Section("Shortcut and pasting") {
                Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled)
                if model.settings.hotkeyEnabled {
                    TextField("Shortcut", text: $model.settings.hotkey, prompt: Text("ctrl+cmd+v"))
                    if let problem = model.hotkeyProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else if let spec = HotkeySpec(model.settings.hotkey) {
                        Text("Press \(spec.description) to open the history.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Paste the chosen item directly", isOn: $model.settings.pasteDirectly)
                    .onChange(of: model.settings.pasteDirectly) { _, on in if on { requestAccessibility() } }
                Text("Needs Accessibility permission, used only to press ⌘V for you. Without it, the item is copied and you paste it yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore copies from") {
                ForEach(model.settings.ignoredApps, id: \.bundleID) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Button("Remove") { model.settings.ignoredApps.removeAll { $0.bundleID == app.bundleID } }
                    }
                }
                Text("Add an app from the menu: Clipboard ▸ Ignore Copies from <app>.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
