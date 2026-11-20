import CryptoKit
import Foundation

/// What was copied.
public enum ClipContent: Equatable, Sendable {
    case text(String)
    /// PNG data.
    case image(Data)
    /// File paths (copied in Finder).
    case files([String])

    public var kind: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .files: return "files"
        }
    }

    /// Identical content → identical hash, used to de-duplicate history.
    public var hash: String {
        var h = SHA256()
        h.update(data: Data(kind.utf8))
        h.update(data: Data([0]))
        switch self {
        case .text(let s): h.update(data: Data(s.utf8))
        case .image(let d): h.update(data: d)
        case .files(let p): h.update(data: Data(p.joined(separator: "\n").utf8))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One line for lists: first non-empty line of text, file names, or "Image".
    public var preview: String {
        switch self {
        case .text(let s):
            let line = s.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? s.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(line.prefix(200))
        case .image:
            return "Image"
        case .files(let paths):
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names.count) files: \(names.prefix(3).joined(separator: ", "))"
        }
    }

    var searchableText: String? {
        switch self {
        case .text(let s): return s
        case .files(let p): return p.joined(separator: "\n")
        case .image: return nil
        }
    }
}

/// An app, by bundle id.
public struct AppRef: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One entry in the history.
public struct ClipItem: Identifiable, Equatable, Sendable {
    /// Positive: row id in the database. Negative: a secret, kept in memory only.
    public var id: Int64
    public var content: ClipContent
    public var source: AppRef?
    public var firstCopiedAt: Date
    public var lastUsedAt: Date
    public var pinned: Bool
    /// Set for detected secrets (never written to disk).
    public var secret: SecretMatch?
    /// When a secret is removed.
    public var expiresAt: Date?

    public init(id: Int64, content: ClipContent, source: AppRef?, firstCopiedAt: Date, lastUsedAt: Date,
                pinned: Bool = false, secret: SecretMatch? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.content = content
        self.source = source
        self.firstCopiedAt = firstCopiedAt
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
        self.secret = secret
        self.expiresAt = expiresAt
    }

    public var isSecret: Bool { secret != nil }

    /// Secrets are masked in lists: "One-time code · 48••••".
    public var displayText: String {
        guard let secret else { return content.preview }
        return "\(secret.label) · \(SecretDetector.mask(content.preview))"
    }
}
