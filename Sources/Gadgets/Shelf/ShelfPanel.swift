import AppKit
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// The floating shelf window. Doesn't take focus from the app you're dragging from.
@MainActor
final class ShelfPanel {
    private let model: ShelfGadget.Model
    private weak var gadget: ShelfGadget?
    private var panel: NSPanel?
    private var pruneTimer: Timer?
    static let size = NSSize(width: 300, height: 230)

    init(model: ShelfGadget.Model, gadget: ShelfGadget) {
        self.model = model
        self.gadget = gadget
    }

    func show(nearCursor: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        var origin: NSPoint
        if nearCursor {
            // Up and to the right of the cursor, so you can drop straight onto it.
            origin = NSPoint(x: mouse.x + 40, y: mouse.y - Self.size.height / 2)
        } else {
            origin = NSPoint(x: f.maxX - Self.size.width - 24, y: f.midY - Self.size.height / 2)
        }
        origin.x = min(max(origin.x, f.minX + 8), f.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, f.minY + 8), f.maxY - Self.size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        // Files dragged out to another folder get moved; drop them from the shelf.
        pruneTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.model.shelf.pruneMissing() }
        }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    func hide() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 220, height: 160)
        panel.contentView = NSHostingView(rootView: ShelfView(
            model: model,
            add: { [weak self] urls in self?.gadget?.add(urls) },
            remove: { [weak self] url in self?.gadget?.remove(url) },
            close: { [weak self] in self?.gadget?.clearAndClose() }))
        return panel
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfGadget.Model
    let add: ([URL]) -> Void
    let remove: (URL) -> Void
    let close: () -> Void
    @State private var targeted = false

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text(model.shelf.items.isEmpty ? "Shelf" : model.shelf.summary)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.shelf.items.count > 1 {
                    DragAllHandle(urls: model.shelf.items)
                        .frame(width: 70, height: 20)
                        .help("Drag all files at once")
                }
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Empty the shelf and close it (your files aren't touched)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                if model.shelf.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("Drop files here").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.shelf.items, id: \.self) { url in
                                ShelfItemView(url: url, remove: { remove(url) })
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                    .padding(8)
            )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { add([url]) }
            }
        }
    }
}

private struct ShelfItemView: View {
    let url: URL
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: 76, height: 78)
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from shelf (the file isn't touched)")
            }
        }
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}

/// "Drag all": starts one drag session carrying every file on the shelf.
private struct DragAllHandle: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> DragAllView { DragAllView() }
    func updateNSView(_ view: DragAllView, context: Context) { view.urls = urls }

    final class DragAllView: NSView, NSDraggingSource {
        var urls: [URL] = []

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
            let text = "Drag all" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.controlAccentColor]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
        }

        override func mouseDragged(with event: NSEvent) {
            let items = urls.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(min(i, 4)) * 4
                item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 32, height: 32), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }
    }
}
