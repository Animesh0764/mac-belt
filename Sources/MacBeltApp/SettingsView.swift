import AppKit
import BeltKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: RegistryModel
    let settingsFolder: URL

    var body: some View {
        TabView {
            GeneralSettings(settingsFolder: settingsFolder)
                .tabItem { Label("General", systemImage: "gearshape") }
            ForEach(model.registry.runningGadgets.indices, id: \.self) { i in
                let gadget = model.registry.runningGadgets[i]
                let info = type(of: gadget).info
                Group {
                    if let view = gadget.settingsView() {
                        view
                    } else {
                        Text("\(info.name) has no settings.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .tabItem { Label(info.name, systemImage: info.symbol) }
            }
        }
        .padding(.top, 8)
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct GeneralSettings: View {
    let settingsFolder: URL
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Mac Belt at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Your settings") {
                Text("Plain JSON files you can read or edit:").foregroundStyle(.secondary)
                HStack {
                    Text(settingsFolder.path(percentEncoded: false))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([settingsFolder])
                    }
                }
            }
            Section("About") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                LabeledContent("Version", value: version)
                Link("Source code on GitHub", destination: SupportInfo.repository)
                Link("Report a bug or suggest a gadget", destination: SupportInfo.issues)
                Text("Mac Belt is free and open source (MIT). It collects nothing and has no account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription). It works once Mac Belt is installed (make install)."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
