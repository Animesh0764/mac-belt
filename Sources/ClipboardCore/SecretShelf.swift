import Foundation

/// Detected secrets live here, in memory only, until they expire. Never written to disk.
public struct SecretShelf: Sendable {
    public private(set) var items: [ClipItem] = []
    private var nextID: Int64 = -1

    public init() {}

    /// Adds a secret (or refreshes the timer if the same secret is copied again).
    @discardableResult
    public mutating func add(_ content: ClipContent, secret: SecretMatch, source: AppRef?,
                             now: Date, lifetime: TimeInterval) -> ClipItem {
        let expires = now.addingTimeInterval(lifetime)
        if let i = items.firstIndex(where: { $0.content == content }) {
            items[i].lastUsedAt = now
            items[i].expiresAt = expires
            let item = items.remove(at: i)
            items.insert(item, at: 0)
            return item
        }
        let item = ClipItem(id: nextID, content: content, source: source, firstCopiedAt: now, lastUsedAt: now,
                            secret: secret, expiresAt: expires)
        nextID -= 1
        items.insert(item, at: 0)
        return item
    }

    /// Removes and returns secrets whose time is up.
    public mutating func expire(now: Date) -> [ClipItem] {
        let gone = items.filter { ($0.expiresAt ?? .distantFuture) <= now }
        items.removeAll { ($0.expiresAt ?? .distantFuture) <= now }
        return gone
    }

    /// Restart a secret's timer (when it's copied again from history).
    public mutating func refresh(_ id: Int64, now: Date, lifetime: TimeInterval) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].expiresAt = now.addingTimeInterval(lifetime)
        items[i].lastUsedAt = now
    }

    public mutating func remove(_ id: Int64) {
        items.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        items.removeAll()
    }

    public func item(_ id: Int64) -> ClipItem? {
        items.first { $0.id == id }
    }

    /// "wipes in 42 s"
    public static func countdown(_ item: ClipItem, now: Date) -> String {
        guard let end = item.expiresAt else { return "" }
        return "removed in \(max(0, Int(end.timeIntervalSince(now).rounded(.up)))) s"
    }
}
