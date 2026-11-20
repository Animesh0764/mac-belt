import XCTest
@testable import ClipboardCore

final class ClipStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let safari = AppRef(bundleID: "com.apple.Safari", name: "Safari")
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-clip-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddAndListNewestFirst() throws {
        let s = try ClipStore(url: nil)
        try s.add(.text("one"), source: safari, at: t0)
        try s.add(.text("two"), source: nil, at: t0.addingTimeInterval(1))
        let items = try s.items()
        XCTAssertEqual(items.map(\.content.preview), ["two", "one"])
        XCTAssertEqual(items.last?.source, safari)
    }

    func testDuplicateMovesToTopInsteadOfRepeating() throws {
        let s = try ClipStore(url: nil)
        let first = try s.add(.text("same"), source: nil, at: t0)
        try s.add(.text("other"), source: nil, at: t0.addingTimeInterval(1))
        let again = try s.add(.text("same"), source: safari, at: t0.addingTimeInterval(2))
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(try s.count(), 2)
        XCTAssertEqual(try s.items().first?.content, .text("same"))
        XCTAssertEqual(again.firstCopiedAt, t0, "first copy time is kept")
        XCTAssertEqual(again.source, safari)
    }

    func testAllContentKindsRoundTrip() throws {
        let s = try ClipStore(url: nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3])
        try s.add(.image(png), source: nil, at: t0)
        try s.add(.files(["/tmp/a.txt", "/tmp/b c.pdf"]), source: nil, at: t0.addingTimeInterval(1))
        try s.add(.text("multi\nline\n  text"), source: nil, at: t0.addingTimeInterval(2))
        let items = try s.items()
        XCTAssertEqual(items[0].content, .text("multi\nline\n  text"))
        XCTAssertEqual(items[1].content, .files(["/tmp/a.txt", "/tmp/b c.pdf"]))
        XCTAssertEqual(items[2].content, .image(png))
    }

    func testSearchIsCaseInsensitiveAndSkipsImages() throws {
        let s = try ClipStore(url: nil)
        try s.add(.text("Flight booking PNR ABC123"), source: nil, at: t0)
        try s.add(.text("grocery list"), source: nil, at: t0)
        try s.add(.files(["/Users/me/Booking.pdf"]), source: nil, at: t0)
        try s.add(.image(Data([1, 2, 3])), source: nil, at: t0)
        XCTAssertEqual(Set(try s.items(matching: "BOOKING").map(\.content.preview)),
                       ["Flight booking PNR ABC123", "Booking.pdf"])
        XCTAssertEqual(try s.items(matching: "  ").count, 4, "blank search = everything")
        XCTAssertEqual(try s.items(matching: "%").count, 0, "LIKE wildcards are literal")
    }

    func testPinnedSurvivePruneAndClear() throws {
        let s = try ClipStore(url: nil)
        for i in 0..<10 {
            try s.add(.text("item \(i)"), source: nil, at: t0.addingTimeInterval(Double(i)))
        }
        let keep = try XCTUnwrap(try s.items().last)  // oldest
        try s.setPinned(keep.id, true)

        XCTAssertEqual(try s.prune(limit: 3, olderThan: nil), 6)
        let left = try s.items().map(\.content.preview)
        XCTAssertEqual(Set(left), ["item 9", "item 8", "item 7", "item 0"])

        try s.clear(keepPinned: true)
        XCTAssertEqual(try s.items().map(\.content.preview), ["item 0"])
        try s.clear(keepPinned: false)
        XCTAssertEqual(try s.count(), 0)
    }

    func testPruneByAge() throws {
        let s = try ClipStore(url: nil)
        try s.add(.text("old"), source: nil, at: t0)
        try s.add(.text("new"), source: nil, at: t0.addingTimeInterval(86_400 * 40))
        try s.prune(limit: 100, olderThan: t0.addingTimeInterval(86_400 * 10))
        XCTAssertEqual(try s.items().map(\.content.preview), ["new"])
    }

    func testTouchAndDelete() throws {
        let s = try ClipStore(url: nil)
        let a = try s.add(.text("a"), source: nil, at: t0)
        try s.add(.text("b"), source: nil, at: t0.addingTimeInterval(1))
        try s.touch(a.id, at: t0.addingTimeInterval(5))
        XCTAssertEqual(try s.items().first?.content, .text("a"))
        try s.delete(a.id)
        XCTAssertNil(try s.item(a.id))
    }

    func testPersistsOnDiskWithPrivatePermissions() throws {
        let url = dir.appendingPathComponent("clipboard.sqlite")
        do {
            let s = try ClipStore(url: url)
            try s.add(.text("remember me"), source: nil, at: t0)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reopened = try ClipStore(url: url)
        XCTAssertEqual(try reopened.items().map(\.content.preview), ["remember me"])
    }

    func testQuotesAndUnicode() throws {
        let s = try ClipStore(url: nil)
        let tricky = "it's \"quoted\"; DROP TABLE items; -- नमस्ते 🎉"
        try s.add(.text(tricky), source: nil, at: t0)
        XCTAssertEqual(try s.items(matching: "नमस्ते").first?.content, .text(tricky))
        XCTAssertEqual(try s.count(), 1)
    }
}

final class SecretShelfTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let otp = SecretMatch(.oneTimeCode, "One-time code")

    func testExpiry() {
        var shelf = SecretShelf()
        let a = shelf.add(.text("482913"), secret: otp, source: nil, now: t0, lifetime: 60)
        XCTAssertLessThan(a.id, 0, "secrets use negative ids")
        XCTAssertTrue(shelf.expire(now: t0.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(shelf.expire(now: t0.addingTimeInterval(60)).map(\.id), [a.id])
        XCTAssertTrue(shelf.items.isEmpty)
    }

    func testCopyingAgainRestartsTimer() {
        var shelf = SecretShelf()
        let a = shelf.add(.text("482913"), secret: otp, source: nil, now: t0, lifetime: 60)
        let b = shelf.add(.text("482913"), secret: otp, source: nil, now: t0.addingTimeInterval(50), lifetime: 60)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(shelf.items.count, 1)
        XCTAssertTrue(shelf.expire(now: t0.addingTimeInterval(100)).isEmpty)
        shelf.refresh(a.id, now: t0.addingTimeInterval(100), lifetime: 60)
        XCTAssertTrue(shelf.expire(now: t0.addingTimeInterval(150)).isEmpty)
        XCTAssertEqual(shelf.expire(now: t0.addingTimeInterval(160)).count, 1)
    }

    func testCountdownAndDisplay() {
        var shelf = SecretShelf()
        let a = shelf.add(.text("482913"), secret: otp, source: nil, now: t0, lifetime: 60)
        XCTAssertEqual(SecretShelf.countdown(a, now: t0.addingTimeInterval(17.2)), "removed in 43 s")
        XCTAssertEqual(a.displayText, "One-time code · 48••••")
        XCTAssertFalse(a.displayText.contains("482913"))
    }
}

final class ClipboardMiscTests: XCTestCase {
    func testIgnoredPasteboardTypes() {
        XCTAssertTrue(ClipboardRules.shouldIgnore(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardRules.shouldIgnore(types: ["org.nspasteboard.TransientType"]))
        XCTAssertFalse(ClipboardRules.shouldIgnore(types: ["public.utf8-plain-text", "public.html"]))
    }

    func testSettingsDecodeOldFileAndKeepForever() throws {
        let old = try JSONDecoder().decode(ClipboardSettings.self, from: Data(#"{"historyLimit": 50}"#.utf8))
        XCTAssertEqual(old.historyLimit, 50)
        XCTAssertEqual(old.keepDays, 30, "missing → default")
        XCTAssertTrue(old.detectSecrets)
        XCTAssertFalse(old.ignoredApps.isEmpty)

        var forever = ClipboardSettings()
        forever.keepDays = nil
        let data = try JSONEncoder().encode(forever)
        XCTAssertNil(try JSONDecoder().decode(ClipboardSettings.self, from: data).keepDays, "explicit null = forever")
    }

    func testPreview() {
        XCTAssertEqual(ClipContent.text("\n\n  first line  \nsecond").preview, "first line")
        XCTAssertEqual(ClipContent.files(["/a/b/report.pdf"]).preview, "report.pdf")
        XCTAssertEqual(ClipContent.files(["/a/x.png", "/a/y.png"]).preview, "2 files: x.png, y.png")
        XCTAssertEqual(ClipContent.image(Data()).preview, "Image")
        XCTAssertNotEqual(ClipContent.text("a").hash, ClipContent.files(["a"]).hash)
    }

    func testRelativeTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-20), now: now, calendar: cal), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-300), now: now, calendar: cal), "5m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-7200), now: now, calendar: cal), "2h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_400), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-3 * 86_400), now: now, calendar: cal), "Tue")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-20 * 86_400), now: now, calendar: cal), "31 Oct")
    }
}
