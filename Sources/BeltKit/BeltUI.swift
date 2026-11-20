import AppKit
import SwiftUI

/// Shared UI every gadget uses, so they all look like one product.
@MainActor
public final class BeltUI {
    /// Called when a gadget sets or clears its menu bar badge.
    public var onBadgeChange: (() -> Void)?
    private var badges: [String: (symbol: String, priority: Int)] = [:]
    private let toaster = Toaster()
    /// Tests turn this off so no windows appear.
    public var toastsEnabled = true

    public init() {}

    /// Show `symbol` in the menu bar icon (nil clears it). If several gadgets set one,
    /// the highest priority wins (ties: by gadget id, so it's stable).
    public func setBadge(_ symbol: String?, for gadgetID: String, priority: Int = 0) {
        let new = symbol.map { (symbol: $0, priority: priority) }
        guard badges[gadgetID]?.symbol != new?.symbol || badges[gadgetID]?.priority != new?.priority else { return }
        badges[gadgetID] = new
        onBadgeChange?()
    }

    public var currentBadge: String? {
        badges.sorted { a, b in
            a.value.priority != b.value.priority ? a.value.priority > b.value.priority : a.key < b.key
        }.first?.value.symbol
    }

    public func toast(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.8) {
        guard toastsEnabled else { return }
        toaster.show(text: text, symbol: symbol, duration: duration)
    }
}

/// A small pill near the bottom of the screen. Click-through, never takes focus.
@MainActor
final class Toaster {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(text: String, symbol: String?, duration: TimeInterval) {
        hideWork?.cancel()
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 90,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

struct ToastView: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize()
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(16)
    }
}
