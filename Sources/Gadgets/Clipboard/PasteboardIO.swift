import AppKit
import ClipboardCore

/// Reading from / writing to an NSPasteboard. Kept separate so tests can use a private pasteboard.
enum PasteboardIO {
    /// What's on the pasteboard, or nil if it's empty, too big, or something we don't record.
    /// Priority: files (Finder) > text > image.
    static func read(_ pb: NSPasteboard, storeImages: Bool) -> ClipContent? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let s = pb.string(forType: .string) {
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  s.count <= ClipboardRules.maxTextLength else { return nil }
            return .text(s)
        }
        if storeImages, let png = pngData(pb), png.count <= ClipboardRules.maxImageBytes {
            return .image(png)
        }
        return nil
    }

    static func types(_ pb: NSPasteboard) -> [String] {
        pb.types?.map(\.rawValue) ?? []
    }

    /// Puts an item back on the pasteboard. Returns the new change count.
    @discardableResult
    static func write(_ content: ClipContent, to pb: NSPasteboard) -> Int {
        pb.clearContents()
        switch content {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let data):
            if let image = NSImage(data: data) { pb.writeObjects([image]) } else { pb.setData(data, forType: .png) }
        case .files(let paths):
            pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        }
        return pb.changeCount
    }

    private static func pngData(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Simulates ⌘V in the frontmost app. Needs Accessibility; does nothing without it.
enum Paster {
    static func pasteIntoFrontmostApp() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }
}
