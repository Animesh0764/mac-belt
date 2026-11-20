import CoreGraphics
import Foundation
import ImageIO

protocol RegionCapturer: Sendable {
    /// Lets you drag a box on screen (or press Space to pick a window). nil if you pressed Esc.
    func capture() async -> CGImage?
}

/// Uses macOS's own screenshot picker (`/usr/sbin/screencapture -i`), so the box, Esc,
/// Space-for-window and multiple displays all work exactly like ⌘⇧4.
/// The image goes to a private temp file, is read once, then deleted.
struct ScreencaptureTool: RegionCapturer {
    func capture() async -> CGImage? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacBeltTextGrab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive box, -x no shutter sound, -o no window shadow
        p.arguments = ["-i", "-x", "-o", file.path]
        let finished: Bool = await withCheckedContinuation { cont in
            p.terminationHandler = { _ in cont.resume(returning: true) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                cont.resume(returning: false)
            }
        }
        guard finished,
              let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return image
    }
}
