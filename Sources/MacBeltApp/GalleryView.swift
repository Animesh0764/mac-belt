import BeltKit
import SwiftUI

/// The gadget gallery: one card per gadget with an on/off switch.
/// This window is the launch screenshot, so keep it tidy.
struct GalleryView: View {
    @ObservedObject var model: RegistryModel
    let welcome: Bool
    let openSupport: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.infos, id: \.id) { info in
                        GadgetCard(info: info, isOn: model.isOn(info.id), error: model.error(info.id),
                                   toggle: { model.set(info, on: $0) })
                    }
                    ComingSoonCard()
                }
                footer
            }
            .padding(24)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(welcome ? "Welcome to Mac Belt" : "Gadgets")
                .font(.system(size: 26, weight: .bold))
            Text(welcome
                 ? "Small Mac tools in one menu bar icon. Free and open source. Switch on only what you want; gadgets that are off use nothing."
                 : "Switch gadgets on or off. Gadgets that are off use no CPU and ask for no permissions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if welcome {
                Label("Mac Belt lives in your menu bar (look for the wrench icon).", systemImage: "menubar.arrow.up.rectangle")
                    .font(.callout)
                    .padding(.top, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Mac Belt is free. No paid tier, no tracking, no account.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("☕ Support Mac Belt", action: openSupport)
        }
    }
}

struct GadgetCard: View {
    let info: GadgetInfo
    let isOn: Bool
    let error: String?
    let toggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: info.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(isOn ? 0.18 : 0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { isOn }, set: toggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(info.name).font(.headline)
            Text(info.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let replaces = info.replaces {
                Text("Replaces \(replaces)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            chips
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isOn ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var chips: some View {
        HStack(spacing: 6) {
            if info.permissions.isEmpty {
                Chip(text: "No permissions", symbol: "checkmark.shield")
            } else {
                ForEach(info.permissions.map(\.description).sorted(), id: \.self) { p in
                    Chip(text: p, symbol: "lock.shield")
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

struct ComingSoonCard: View {
    var body: some View {
        Text("More coming soon...")
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 190)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.secondary.opacity(0.5)))
    }
}
