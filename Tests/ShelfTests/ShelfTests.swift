import AppKit
import XCTest
@testable import BeltKit
@testable import ShelfCore
@testable import ShelfGadget

final class ShakeDetectorTests: XCTestCase {
    /// x positions sampled every 1/60 s.
    private func run(_ xs: [Double], start: TimeInterval = 0, dt: TimeInterval = 1.0 / 60,
                     _ d: inout ShakeDetector) -> Bool {
        var fired = false
        for (i, x) in xs.enumerated() where d.feed(x: x, at: start + Double(i) * dt) { fired = true }
        return fired
    }

    private func sweep(_ from: Double, _ to: Double, steps: Int = 6) -> [Double] {
        (1...steps).map { from + (to - from) * Double($0) / Double(steps) }
    }

    func testQuickShakeFires() {
        var d = ShakeDetector()
        let xs = [500] + sweep(500, 580) + sweep(580, 500) + sweep(500, 580) + sweep(580, 500)
        XCTAssertTrue(run(xs, &d))
    }

    func testSmoothDragDoesNotFire() {
        var d = ShakeDetector()
        XCTAssertFalse(run(sweep(100, 900, steps: 60), &d))
    }

    func testOneTurnBackDoesNotFire() {
        var d = ShakeDetector()
        XCTAssertFalse(run([500] + sweep(500, 700) + sweep(700, 400), &d))
    }

    func testJitterDoesNotFire() {
        var d = ShakeDetector()
        let xs = (0..<120).map { 500 + Double($0 % 2 == 0 ? 8 : -8) }  // hand tremor, 16 px
        XCTAssertFalse(run(xs, &d))
    }

    func testSlowWavingDoesNotFire() {
        var d = ShakeDetector()
        // Same shape as a shake but spread over ~3 s.
        let xs = [500] + sweep(500, 580, steps: 45) + sweep(580, 500, steps: 45) + sweep(500, 580, steps: 45) + sweep(580, 500, steps: 45)
        XCTAssertFalse(run(xs, &d))
    }
}

final class DragShakeTrackerTests: XCTestCase {
    private let shake: [Double] = [500, 520, 540, 560, 580, 560, 540, 520, 500, 520, 540, 560, 580, 560, 540, 520, 500]

    private func feed(_ t: inout DragShakeTracker, down: Bool, xs: [Double], drag: Int, start: inout TimeInterval) -> Bool {
        var fired = false
        for x in xs {
            if t.tick(buttonDown: down, x: x, dragChangeCount: drag, at: start) { fired = true }
            start += 1.0 / 60
        }
        return fired
    }

    func testShakeDuringFileDragOpensShelf() {
        var t = DragShakeTracker(), clock: TimeInterval = 0
        _ = feed(&t, down: false, xs: [500], drag: 7, start: &clock)          // idle
        XCTAssertTrue(feed(&t, down: true, xs: shake, drag: 8, start: &clock)) // drag started → count changed
    }

    func testShakeWithoutDragDoesNothing() {
        // Moving a window or selecting text: button down, but no drag pasteboard change.
        var t = DragShakeTracker(), clock: TimeInterval = 0
        _ = feed(&t, down: false, xs: [500], drag: 7, start: &clock)
        XCTAssertFalse(feed(&t, down: true, xs: shake, drag: 7, start: &clock))
    }

    func testFiresOncePerDragThenAgainNextDrag() {
        var t = DragShakeTracker(), clock: TimeInterval = 0
        _ = feed(&t, down: false, xs: [500], drag: 1, start: &clock)
        XCTAssertTrue(feed(&t, down: true, xs: shake, drag: 2, start: &clock))
        XCTAssertFalse(feed(&t, down: true, xs: shake, drag: 2, start: &clock), "only once per drag")
        _ = feed(&t, down: false, xs: [500], drag: 2, start: &clock)          // released
        XCTAssertTrue(feed(&t, down: true, xs: shake, drag: 3, start: &clock))
    }

    func testNoIdleSampleYetMeansNoFalseStart() {
        // If we only start watching mid-press, we can't know a drag began; stay quiet.
        var t = DragShakeTracker(), clock: TimeInterval = 0
        XCTAssertFalse(feed(&t, down: true, xs: shake, drag: 9, start: &clock))
    }
}

final class ShelfModelTests: XCTestCase {
    func testAddDedupesAndIgnoresNonFiles() {
        var s = Shelf()
        let a = URL(fileURLWithPath: "/tmp/a.txt"), b = URL(fileURLWithPath: "/tmp/./b.txt")
        XCTAssertEqual(s.add([a, b, a, URL(string: "https://example.com")!]), 2)
        XCTAssertEqual(s.add([URL(fileURLWithPath: "/tmp/b.txt")]), 0, "standardized paths dedupe")
        XCTAssertEqual(s.summary, "2 files")
        s.remove(a)
        XCTAssertEqual(s.summary, "1 file")
        s.removeAll()
        XCTAssertEqual(s.summary, "Empty")
    }

    func testPruneMissing() {
        var s = Shelf()
        s.add([URL(fileURLWithPath: "/tmp/keep"), URL(fileURLWithPath: "/tmp/gone")])
        XCTAssertEqual(s.pruneMissing(exists: { $0.lastPathComponent == "keep" }), 1)
        XCTAssertEqual(s.items.map(\.lastPathComponent), ["keep"])
    }

    func testSettingsDecodeOldFile() throws {
        let s = try JSONDecoder().decode(ShelfSettings.self, from: Data(#"{"shakeToOpen": false}"#.utf8))
        XCTAssertFalse(s.shakeToOpen)
        XCTAssertEqual(s.hotkey, "ctrl+opt+s")
    }
}

@MainActor
final class ShelfGadgetTests: XCTestCase {
    private var dir: URL!
    private var hotkeys: HotkeyCenter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-shelf-\(UUID().uuidString)")
        hotkeys = HotkeyCenter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGadget(hotkey: String? = nil) throws -> ShelfGadget {
        var s = ShelfSettings()
        if let hotkey { s.hotkey = hotkey } else { s.hotkeyEnabled = false }
        let store = SettingsStore(directory: dir)
        try store.save(s, key: "gadget.shelf")
        let ui = BeltUI()
        ui.toastsEnabled = false
        let ctx = GadgetContext(id: "shelf", store: store, hotkeys: hotkeys, permissions: PermissionBroker(),
                                events: EventBus(), ui: ui)
        let g = ShelfGadget(context: ctx)
        g.presentsPanel = false
        return g
    }

    func testShakeWhileDraggingShowsShelf() throws {
        let g = try makeGadget()
        var down = false, x = 500.0, drag = 1, t: TimeInterval = 0
        g.mouseButtonDown = { down }
        g.mouseX = { x }
        g.dragChangeCount = { drag }
        g.clock = { t }
        try g.start()
        g.tick()                       // idle sample
        down = true; drag = 2          // a file drag begins
        for target in [580.0, 500, 580, 500] {
            for i in 1...5 {
                x += (target - x) / Double(6 - i)
                t += 1.0 / 60
                g.tick()
            }
        }
        XCTAssertTrue(g.isShelfShown)
        g.stop()
        XCTAssertFalse(g.isShelfShown)
    }

    func testAddRemoveClear() throws {
        let g = try makeGadget()
        try g.start()
        let file = dir.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: file)
        g.add([file, file])
        XCTAssertEqual(g.model.shelf.items.count, 1)
        g.showShelf()
        XCTAssertEqual(g.menuItems().first?.title, "Shelf · 1 file")
        g.clearAndClose()
        XCTAssertTrue(g.model.shelf.items.isEmpty)
        XCTAssertFalse(g.isShelfShown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "clearing never touches files")
        g.stop()
    }

    func testShakeCanBeTurnedOff() throws {
        let g = try makeGadget()
        try g.start()
        XCTAssertTrue(g.menuItems().contains { $0.title == "Shake While Dragging to Open" && $0.state == .on })
        g.stop()
    }

    func testStartStopHundredTimesLeavesNothingBehind() throws {
        _ = try makeGadget(hotkey: "ctrl+opt+cmd+shift+f6")
        for _ in 0..<100 {
            let ui = BeltUI(); ui.toastsEnabled = false
            let ctx = GadgetContext(id: "shelf", store: SettingsStore(directory: dir), hotkeys: hotkeys,
                                    permissions: PermissionBroker(), events: EventBus(), ui: ui)
            let g = ShelfGadget(context: ctx)
            g.presentsPanel = false
            try g.start()
            XCTAssertEqual(hotkeys.registeredCount, 1)
            g.stop()
        }
        XCTAssertEqual(hotkeys.registeredCount, 0)
    }
}
