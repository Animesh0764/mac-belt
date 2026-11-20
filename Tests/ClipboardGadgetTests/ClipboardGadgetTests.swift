import AppKit
import XCTest
@testable import BeltKit
@testable import ClipboardCore
@testable import ClipboardGadget

/// Drives the real gadget against a private, uniquely-named pasteboard, so the tests
/// never touch your actual clipboard.
@MainActor
final class ClipboardGadgetTests: XCTestCase {
    private var dir: URL!
    private var pb: NSPasteboard!
    private var ui: BeltUI!
    private var events: EventBus!
    private var hotkeys: HotkeyCenter!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let notes = AppRef(bundleID: "com.apple.Notes", name: "Notes")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-clipgadget-\(UUID().uuidString)")
        pb = NSPasteboard.withUniqueName()
        ui = BeltUI()
        ui.toastsEnabled = false
        events = EventBus()
        hotkeys = HotkeyCenter()
    }

    override func tearDown() async throws {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGadget(_ configure: (inout ClipboardSettings) -> Void = { _ in }) throws -> ClipboardGadget {
        var settings = ClipboardSettings()
        settings.hotkeyEnabled = false
        configure(&settings)
        let store = SettingsStore(directory: dir)
        try store.save(settings, key: "gadget.clipboard")
        let ctx = GadgetContext(id: "clipboard", store: store, hotkeys: hotkeys, permissions: PermissionBroker(),
                                events: events, ui: ui)
        let g = ClipboardGadget(context: ctx, pasteboard: pb)
        g.now = { [unowned self] in self.clock }
        g.frontmostApp = { [unowned self] in self.notes }
        g.pasteHandler = { true }
        return g
    }

    private func copy(_ s: String, extraTypes: [String] = []) {
        pb.clearContents()
        pb.declareTypes([.string] + extraTypes.map { NSPasteboard.PasteboardType($0) }, owner: nil)
        pb.setString(s, forType: .string)
        for t in extraTypes { pb.setString("", forType: NSPasteboard.PasteboardType(t)) }
    }

    func testIgnoresWhatWasAlreadyThereThenRecordsNewCopies() throws {
        copy("before start")
        let g = try makeGadget()
        try g.start()
        g.poll()
        XCTAssertTrue(g.history().isEmpty)

        copy("hello")
        g.poll()
        g.poll()  // no change → no duplicate
        let items = g.history()
        XCTAssertEqual(items.map(\.content), [.text("hello")])
        XCTAssertEqual(items.first?.source, notes)
        g.stop()
    }

    func testSecretGoesToShelfNotDiskAndIsWipedAfterExpiry() throws {
        let g = try makeGadget()
        try g.start()
        copy("Your OTP is 482913")
        g.poll()
        XCTAssertEqual(g.history().count, 1)
        XCTAssertTrue(g.history()[0].isSecret)
        XCTAssertEqual(try g.store?.count(), 0, "secrets are never written to the database")

        clock = clock.addingTimeInterval(59)
        g.expireSecrets()
        XCTAssertEqual(pb.string(forType: .string), "Your OTP is 482913")

        clock = clock.addingTimeInterval(1)
        g.expireSecrets()
        XCTAssertTrue(g.history().isEmpty)
        XCTAssertNil(pb.string(forType: .string), "clipboard wiped")

        // The wipe itself must not be recorded as a new copy.
        g.poll()
        XCTAssertTrue(g.history().isEmpty)
        g.stop()

        // And the secret isn't anywhere in the database file.
        let db = try Data(contentsOf: dir.appendingPathComponent("clipboard.sqlite"))
        XCTAssertNil(db.range(of: Data("482913".utf8)))
    }

    func testDoesNotWipeIfUserCopiedSomethingElse() throws {
        let g = try makeGadget()
        try g.start()
        copy("482913")
        g.poll()
        clock = clock.addingTimeInterval(10)
        copy("an ordinary note")
        g.poll()
        clock = clock.addingTimeInterval(60)
        g.expireSecrets()
        XCTAssertEqual(pb.string(forType: .string), "an ordinary note")
        XCTAssertEqual(g.history().map(\.content), [.text("an ordinary note")])
        g.stop()
    }

    func testWipeCanBeTurnedOff() throws {
        let g = try makeGadget { $0.wipeClipboard = false }
        try g.start()
        copy("482913")
        g.poll()
        clock = clock.addingTimeInterval(61)
        g.expireSecrets()
        XCTAssertTrue(g.history().isEmpty, "still removed from history")
        XCTAssertEqual(pb.string(forType: .string), "482913", "but left on the clipboard")
        g.stop()
    }

    func testStoppingWipesPendingSecret() throws {
        let g = try makeGadget()
        try g.start()
        copy("482913")
        g.poll()
        g.stop()
        XCTAssertNil(pb.string(forType: .string), "secrets don't outlive the gadget")
    }

    func testSecretDetectionOff() throws {
        let g = try makeGadget { $0.detectSecrets = false }
        try g.start()
        copy("482913")
        g.poll()
        XCTAssertEqual(try g.store?.count(), 1)
        XCTAssertFalse(g.history()[0].isSecret)
        g.stop()
    }

    func testPasswordManagerMarkersAndIgnoredApps() throws {
        let g = try makeGadget()
        try g.start()
        copy("correct horse battery staple", extraTypes: ["org.nspasteboard.ConcealedType"])
        g.poll()
        XCTAssertTrue(g.history().isEmpty)

        g.frontmostApp = { AppRef(bundleID: "com.1password.1password", name: "1Password") }
        copy("from 1password without markers")
        g.poll()
        XCTAssertTrue(g.history().isEmpty)

        g.frontmostApp = { [unowned self] in self.notes }
        g.ignore(notes)
        copy("from notes, now ignored")
        g.poll()
        XCTAssertTrue(g.history().isEmpty)
        g.stop()
    }

    func testPauseAndPresentationPause() throws {
        let g = try makeGadget()
        try g.start()
        g.model.paused = true
        copy("while paused")
        g.poll()
        g.model.paused = false
        events.post(.presentationStarted)
        copy("while presenting")
        g.poll()
        XCTAssertTrue(g.history().isEmpty)
        events.post(.presentationEnded)
        copy("after")
        g.poll()
        XCTAssertEqual(g.history().map(\.content), [.text("after")])
        g.stop()
    }

    func testChoosingPutsItBackWithoutRecordingADuplicate() throws {
        let g = try makeGadget()
        try g.start()
        copy("first")
        g.poll()
        clock = clock.addingTimeInterval(5)
        copy("second")
        g.poll()
        let first = try XCTUnwrap(g.history().last)
        clock = clock.addingTimeInterval(5)
        g.choose(first, paste: false)
        XCTAssertEqual(pb.string(forType: .string), "first")
        g.poll()
        XCTAssertEqual(g.history().map(\.content), [.text("first"), .text("second")], "moved to top, no duplicate")
        g.stop()
    }

    func testChoosingASecretRestartsItsTimer() throws {
        let g = try makeGadget()
        try g.start()
        copy("482913")
        g.poll()
        clock = clock.addingTimeInterval(10)
        copy("note")
        g.poll()
        let secret = try XCTUnwrap(g.history().first { $0.isSecret })
        clock = clock.addingTimeInterval(40)
        g.choose(secret, paste: false)  // back on clipboard at t+50
        clock = clock.addingTimeInterval(30)  // t+80: original timer would have fired at t+60
        g.expireSecrets()
        XCTAssertEqual(pb.string(forType: .string), "482913")
        clock = clock.addingTimeInterval(31)
        g.expireSecrets()
        XCTAssertNil(pb.string(forType: .string))
        g.stop()
    }

    func testPinDeleteSearchAndClear() throws {
        let g = try makeGadget()
        try g.start()
        for (i, s) in ["alpha", "beta", "gamma"].enumerated() {
            clock = clock.addingTimeInterval(Double(i))
            copy(s)
            g.poll()
        }
        let alpha = try XCTUnwrap(g.history().first { $0.content == .text("alpha") })
        g.togglePin(alpha)
        XCTAssertEqual(g.history().first?.content, .text("alpha"), "pinned first")
        XCTAssertEqual(g.history(matching: "ET").map(\.content), [.text("beta")])
        g.delete(try XCTUnwrap(g.history(matching: "beta").first))
        g.clearHistory()
        XCTAssertEqual(g.history().map(\.content), [.text("alpha")], "pinned survives clear")
        g.stop()
    }

    func testSecretsSearchableByLabelOnly() throws {
        let g = try makeGadget()
        try g.start()
        copy("482913")
        g.poll()
        XCTAssertEqual(g.history(matching: "one-time").count, 1)
        XCTAssertTrue(g.history(matching: "4829").isEmpty, "never match on secret content")
        g.stop()
    }

    func testFilesAndImages() throws {
        let g = try makeGadget()
        try g.start()
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/report.pdf") as NSURL])
        g.poll()
        XCTAssertEqual(g.history().first?.content, .files(["/tmp/report.pdf"]))

        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        pb.clearContents()
        pb.writeObjects([image])
        clock = clock.addingTimeInterval(1)
        g.poll()
        guard case .image(let png) = g.history().first?.content else { return XCTFail("expected image") }
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "stored as PNG")
        g.stop()
    }

    func testHistoryLimitPrunes() throws {
        let g = try makeGadget { $0.historyLimit = 3 }
        try g.start()
        for i in 0..<6 {
            clock = clock.addingTimeInterval(1)
            copy("n\(i)")
            g.poll()
        }
        g.prune()
        XCTAssertEqual(g.history().map(\.content.preview), ["n5", "n4", "n3"])
        g.stop()
    }

    func testMenuNeverShowsSecretContent() throws {
        let g = try makeGadget()
        try g.start()
        copy("482913")
        g.poll()
        let titles = flatten(g.menuItems()).map(\.title)
        XCTAssertFalse(titles.contains { $0.contains("482913") }, "\(titles)")
        XCTAssertTrue(titles.contains { $0.contains("One-time code") })
        g.stop()
    }

    /// SCOPE.md §3: off means off.
    func testStartStopHundredTimesLeavesNothingBehind() throws {
        _ = try makeGadget { $0.hotkeyEnabled = true; $0.hotkey = "ctrl+opt+cmd+shift+f8" }
        for _ in 0..<100 {
            let ctx = GadgetContext(id: "clipboard", store: SettingsStore(directory: dir), hotkeys: hotkeys,
                                    permissions: PermissionBroker(), events: events, ui: ui)
            let g = ClipboardGadget(context: ctx, pasteboard: pb)
            try g.start()
            XCTAssertEqual(hotkeys.registeredCount, 1)
            g.stop()
            XCTAssertNil(g.store)
        }
        XCTAssertEqual(hotkeys.registeredCount, 0)
        XCTAssertEqual(events.subscriberCount(.presentationStarted), 0)
        XCTAssertEqual(events.subscriberCount(.presentationEnded), 0)
    }

    func testIgnoredAppsMenuIsJustTicks() throws {
        let g = try makeGadget()
        g.isInstalled = { $0 == "com.apple.Notes" || $0 == "com.1password.1password" }
        g.runningApps = { [AppRef(bundleID: "com.apple.Notes", name: "Notes"),
                           AppRef(bundleID: "com.apple.Safari", name: "Safari")] }
        try g.start()
        func apps() -> [(String, Bool)] {
            let sub = g.menuItems().first { $0.title == "Ignored Apps" }?.submenu?.items ?? []
            return sub.filter(\.isEnabled).map { ($0.title, $0.state == .on) }
        }
        // Installed ignored apps (ticked) + running apps (unticked), sorted, nothing else.
        XCTAssertEqual(apps().map(\.0), ["1Password", "Notes", "Safari"])
        XCTAssertEqual(apps().map(\.1), [true, false, false])

        // Clicking toggles.
        let notesItem = g.menuItems().first { $0.title == "Ignored Apps" }!.submenu!.items.first { $0.title == "Notes" }!
        _ = (notesItem.target as AnyObject).perform(notesItem.action)
        XCTAssertTrue(g.isIgnored("com.apple.Notes"))
        XCTAssertEqual(apps().map(\.1), [true, true, false])

        g.unignore(notes)
        XCTAssertEqual(apps().map(\.1), [true, false, false])
        g.stop()
    }

    func testPauseMenuLabelFollowsState() throws {
        let g = try makeGadget()
        try g.start()
        XCTAssertTrue(g.menuItems().contains { $0.title == "Pause Saving History" })
        g.setPaused(true)
        XCTAssertTrue(g.menuItems().contains { $0.title == "Resume Saving History" })
        XCTAssertTrue(g.menuItems().contains { $0.title.hasSuffix("· paused") })
        g.setPaused(false)
        XCTAssertTrue(g.menuItems().contains { $0.title == "Pause Saving History" })
        g.stop()
    }

    private func flatten(_ items: [NSMenuItem]) -> [NSMenuItem] {
        items.flatMap { [$0] + flatten($0.submenu?.items ?? []) }
    }
}
