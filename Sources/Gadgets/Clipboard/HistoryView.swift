import AppKit
import ClipboardCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryPanel.Model
    let choose: (Int) -> Void
    let queryChanged: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onChange(of: model.query) { queryChanged() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                if index == firstUnpinned && firstUnpinned > 0 {
                                    Divider().padding(.vertical, 4)
                                }
                                Row(item: item, index: index, selected: index == model.selection, now: model.now)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { choose(index) }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selection) {
                        if model.items.indices.contains(model.selection) {
                            proxy.scrollTo(model.items[model.selection].id)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Hint(key: "↩", text: model.pasteDirectly ? "Paste" : "Copy")
                if model.pasteDirectly { Hint(key: "⌥↩", text: "Copy") }
                Hint(key: "⌘P", text: "Pin")
                Hint(key: "⌘⌫", text: "Delete")
                Spacer()
                Hint(key: "esc", text: "Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 600, height: 470)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
    }

    private var firstUnpinned: Int {
        model.items.firstIndex { !$0.pinned } ?? model.items.count
    }
}

private struct Row: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            Text(item.displayText)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.isSecret ? Color.orange : Color.primary)
            Spacer(minLength: 8)
            if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            Text(item.isSecret ? SecretShelf.countdown(item, now: now) : RelativeTime.short(item.lastUsedAt, now: now))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(item.isSecret ? Color.orange : Color.secondary)
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption).foregroundStyle(.tertiary).frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .help(item.isSecret ? "Hidden: \(item.secret!.label)" : String(item.content.preview.prefix(500)))
    }

    @ViewBuilder private var icon: some View {
        switch item.content {
        case _ where item.isSecret:
            Image(systemName: "lock.fill").foregroundStyle(.orange)
        case .image(let data):
            if let image = Thumbnails.image(for: item.id, data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
            }
        case .files:
            Image(systemName: "doc").foregroundStyle(.secondary)
        case .text:
            if let icon = AppIcons.icon(item.source?.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            }
        }
    }
}

private struct Hint: View {
    let key: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSNumber, NSImage>()
    static func image(for id: Int64, data: Data) -> NSImage? {
        if let cached = cache.object(forKey: NSNumber(value: id)) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: NSNumber(value: id))
        return image
    }
}
