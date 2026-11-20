import Foundation

/// Files parked on the shelf. Only references (paths); nothing is copied.
public struct Shelf: Sendable, Equatable {
    public private(set) var items: [URL] = []

    public init() {}

    /// Adds files, skipping ones already there. Returns how many were added.
    @discardableResult
    public mutating func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls.map(\.standardizedFileURL) where url.isFileURL && !items.contains(url) {
            items.append(url)
            added += 1
        }
        return added
    }

    public mutating func remove(_ url: URL) {
        items.removeAll { $0 == url.standardizedFileURL }
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    /// Drops files that no longer exist (moved by dragging them out, or deleted).
    @discardableResult
    public mutating func pruneMissing(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Int {
        let before = items.count
        items.removeAll { !exists($0) }
        return before - items.count
    }

    public var summary: String {
        switch items.count {
        case 0: return "Empty"
        case 1: return "1 file"
        default: return "\(items.count) files"
        }
    }
}

public struct ShelfSettings: Codable, Equatable, Sendable {
    public var shakeToOpen = true
    public var hotkeyEnabled = true
    public var hotkey = "ctrl+opt+s"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShelfSettings()
        shakeToOpen = try c.decodeIfPresent(Bool.self, forKey: .shakeToOpen) ?? d.shakeToOpen
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
    }
}
