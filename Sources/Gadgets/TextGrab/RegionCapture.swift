import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: Error {
    /// macOS didn't let Mac Belt see the screen (Screen Recording is off, or needs a relaunch).
    case notAllowed
}

@MainActor
protocol RegionCapturer {
    /// Freezes the screen and lets you drag a box. nil if you pressed Esc.
    func capture() async throws -> CGImage?
}

/// Takes a still of every display first (ScreenCaptureKit, in Mac Belt's own process, so it
/// uses Mac Belt's Screen Recording permission), then shows it full screen so you can drag a
/// box over the frozen picture. Video keeps playing underneath; you select from the still.
/// Nothing is written to disk.
@MainActor
final class FreezeFramePicker: RegionCapturer {
    private var windows: [SelectionWindow] = []
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var previousApp: NSRunningApplication?

    func capture() async throws -> CGImage? {
        let shots = try await Self.captureDisplays()
        guard !shots.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            continuation = cont
            for shot in shots {
                let w = SelectionWindow(screen: shot.screen, image: shot.image) { [weak self] image in
                    self?.finish(image)
                }
                windows.append(w)
            }
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            // Start on the screen the cursor is on.
            let mouse = NSEvent.mouseLocation
            let first = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
            for w in windows { w.orderFrontRegardless() }
            first?.makeKey()
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ image: CGImage?) {
        NSCursor.pop()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        // Give focus back to the app you were in.
        if let app = previousApp, app != NSRunningApplication.current { app.activate() }
        previousApp = nil
        continuation?.resume(returning: image)
        continuation = nil
    }

    private struct Shot {
        let screen: NSScreen
        let image: CGImage
    }

    private static func captureDisplays() async throws -> [Shot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.notAllowed
        }
        // Leave Mac Belt's own windows (toasts, panels) out of the picture.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.capturesAudio = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                shots.append(Shot(screen: screen, image: image))
            } catch {
                throw CaptureError.notAllowed
            }
        }
        return shots
    }
}

/// A borderless full-screen window showing the frozen screen, dimmed, with the box you drag
/// shown bright. Esc cancels.
private final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, image: CGImage, done: @escaping (CGImage?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
        contentView = SelectionView(image: image, done: done)
    }
}

private final class SelectionView: NSView {
    private let image: CGImage
    private let done: (CGImage?) -> Void
    private var start: NSPoint?
    private var current: NSPoint?
    private var finished = false

    init(image: CGImage, done: @escaping (CGImage?) -> Void) {
        self.image = image
        self.done = done
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let a = start, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
        if let sel = selection {
            // The selected part, undimmed.
            ctx.saveGState()
            ctx.clip(to: sel)
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
        } else {
            let hint = "Drag over the text to copy it  ·  Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                        .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attrs)
            let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 120,
                              width: size.width + 28, height: size.height + 14)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            hint.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 7), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let sel = selection, sel.width >= 4, sel.height >= 4 else {
            // A click, not a drag: start over.
            start = nil; current = nil; needsDisplay = true
            return
        }
        finish(crop(sel))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) }  // Esc
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    private func finish(_ result: CGImage?) {
        guard !finished else { return }
        finished = true
        done(result)
    }

    /// View rect (points, bottom-left origin) → the same pixels in the still (top-left origin).
    private func crop(_ rect: NSRect) -> CGImage? {
        let sx = CGFloat(image.width) / bounds.width
        let sy = CGFloat(image.height) / bounds.height
        let pixels = CGRect(x: rect.minX * sx, y: (bounds.height - rect.maxY) * sy,
                            width: rect.width * sx, height: rect.height * sy).integral
        return image.cropping(to: pixels)
    }
}
