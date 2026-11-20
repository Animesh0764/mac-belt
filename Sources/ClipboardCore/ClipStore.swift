import Foundation
import SQLite3

/// Clipboard history on disk (SQLite). Secrets never go in here; see `SecretShelf`.
/// The file is readable only by you (0600).
public final class ClipStore {
    public enum StoreError: Error, CustomStringConvertible {
        case sqlite(String)
        public var description: String {
            switch self { case .sqlite(let m): return "Clipboard database: \(m)" }
        }
    }

    private var db: OpaquePointer?
    public let url: URL?

    /// Opens (or creates) the database at `url`. Pass nil for an in-memory store (tests).
    public init(url: URL?) throws {
        self.url = url
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            db = nil
            throw StoreError.sqlite(message)
        }
        if let url {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS items (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                kind        TEXT NOT NULL,
                text        TEXT,
                data        BLOB,
                hash        TEXT NOT NULL UNIQUE,
                source_id   TEXT,
                source_name TEXT,
                first_at    REAL NOT NULL,
                last_at     REAL NOT NULL,
                pinned      INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS items_last ON items(pinned, last_at);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Writes

    /// Adds content, or moves an identical existing entry to the top. Returns the entry.
    @discardableResult
    public func add(_ content: ClipContent, source: AppRef?, at date: Date) throws -> ClipItem {
        let hash = content.hash
        try run("""
            INSERT INTO items (kind, text, data, hash, source_id, source_name, first_at, last_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET last_at = excluded.last_at,
                source_id = excluded.source_id, source_name = excluded.source_name
            """, [.text(content.kind), .textOrNull(content.searchableText), .blobOrNull(content.imageData),
                  .text(hash), .textOrNull(source?.bundleID), .textOrNull(source?.name),
                  .double(date.timeIntervalSince1970), .double(date.timeIntervalSince1970)])
        guard let item = try query("SELECT * FROM items WHERE hash = ?", [.text(hash)]).first else {
            throw StoreError.sqlite("insert vanished")
        }
        return item
    }

    /// Mark as just used (moves it to the top).
    public func touch(_ id: Int64, at date: Date) throws {
        try run("UPDATE items SET last_at = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .int(id)])
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try run("UPDATE items SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .int(id)])
    }

    public func delete(_ id: Int64) throws {
        try run("DELETE FROM items WHERE id = ?", [.int(id)])
    }

    public func clear(keepPinned: Bool = true) throws {
        try run(keepPinned ? "DELETE FROM items WHERE pinned = 0" : "DELETE FROM items", [])
    }

    /// Keeps the newest `limit` unpinned items, and drops unpinned items older than `olderThan`.
    /// Pinned items are never pruned. Returns how many were removed.
    @discardableResult
    public func prune(limit: Int, olderThan: Date?) throws -> Int {
        let before = try count()
        if let olderThan {
            try run("DELETE FROM items WHERE pinned = 0 AND last_at < ?", [.double(olderThan.timeIntervalSince1970)])
        }
        try run("""
            DELETE FROM items WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0 ORDER BY last_at DESC, id DESC LIMIT ?)
            """, [.int(Int64(max(0, limit)))])
        return before - (try count())
    }

    // MARK: - Reads

    /// Newest first. `matching` filters by case-insensitive substring of text / file paths.
    public func items(matching search: String? = nil, limit: Int = 500) throws -> [ClipItem] {
        let q = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if q.isEmpty {
            return try query("SELECT * FROM items ORDER BY last_at DESC, id DESC LIMIT ?", [.int(Int64(limit))])
        }
        return try query("""
            SELECT * FROM items WHERE text IS NOT NULL AND instr(lower(text), lower(?)) > 0
            ORDER BY last_at DESC, id DESC LIMIT ?
            """, [.text(q), .int(Int64(limit))])
    }

    public func item(_ id: Int64) throws -> ClipItem? {
        try query("SELECT * FROM items WHERE id = ?", [.int(id)]).first
    }

    public func count() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM items", &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - SQLite plumbing

    enum Value {
        case text(String), int(Int64), double(Double), blob(Data), null
        static func textOrNull(_ s: String?) -> Value { s.map(Value.text) ?? .null }
        static func blobOrNull(_ d: Data?) -> Value { d.map(Value.blob) ?? .null }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ values: [Value]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        var stmt: OpaquePointer?
        try prepare(sql, &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ values: [Value]) throws -> [ClipItem] {
        var stmt: OpaquePointer?
        try prepare(sql, &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, values)
        var out: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = row(stmt) { out.append(item) }
        }
        return out
    }

    // Column order matches CREATE TABLE.
    private func row(_ s: OpaquePointer?) -> ClipItem? {
        func text(_ i: Int32) -> String? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
        }
        let id = sqlite3_column_int64(s, 0)
        let content: ClipContent
        switch text(1) {
        case "text": content = .text(text(2) ?? "")
        case "files": content = .files((text(2) ?? "").split(separator: "\n").map(String.init))
        case "image":
            guard let ptr = sqlite3_column_blob(s, 3) else { return nil }
            content = .image(Data(bytes: ptr, count: Int(sqlite3_column_bytes(s, 3))))
        default: return nil
        }
        let source = text(5).map { AppRef(bundleID: $0, name: text(6) ?? $0) }
        return ClipItem(id: id, content: content, source: source,
                        firstCopiedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                        lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
                        pinned: sqlite3_column_int(s, 9) != 0)
    }
}

extension ClipContent {
    var imageData: Data? {
        if case .image(let d) = self { return d }
        return nil
    }
}
