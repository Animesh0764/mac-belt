import AppKit
import SwiftUI

/// A red "Muted" pill that stays on screen while the mic is muted. Click it to unmute.
/// Never takes focus; shown on every Space and over full-screen apps.
@MainActor
final class MutedIndicator {
    var onClick: (() -> Void)?
    private var panel: NSPanel?
    private(set) var isShown = false

    func show(atTop: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: MutedPill(onClick: { [weak self] in self?.onClick?() }))
        let size = host.fittingSize
        panel.contentView = host
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            let y = atTop ? f.maxY - size.height - 6 : f.minY + 24
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        isShown = true
    }

    func hide() {
        panel?.orderOut(nil)
        isShown = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

private struct MutedPill: View {
    let onClick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 7) {
                Image(systemName: "mic.slash.fill").font(.system(size: 13, weight: .bold))
                Text(hover ? "Click to unmute" : "Muted").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(8)
    }
}
