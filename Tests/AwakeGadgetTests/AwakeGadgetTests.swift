import AppKit
import XCTest
@testable import AwakeCore
@testable import AwakeGadget
@testable import BeltKit

@MainActor
final class AwakeGadgetTests: XCTestCase {
    private var dir: URL!
    private var ui: BeltUI!
    private var events: EventBus!
    private var hotkeys: HotkeyCenter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-awake-\(UUID().uuidString)")
        ui = BeltUI()
        ui.toastsEnabled = false
        events = EventBus()
        hotkeys = HotkeyCenter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGadget() -> AwakeGadget {
        let ctx = GadgetContext(id: "awake", store: SettingsStore(directory: dir), hotkeys: hotkeys,
                                permissions: PermissionBroker(), events: events, ui: ui)
        return AwakeGadget(context: ctx)
    }

    func testTurnOnHoldsAssertionAndBadge() throws {
        let g = makeGadget()
        g.runningBundleIDs = { [] }
        try g.start()
        XCTAssertFalse(g.isHoldingAssertion)
        XCTAssertNil(ui.currentBadge)

        g.turnOn(minutes: 30)
        XCTAssertTrue(g.isHoldingAssertion)
        XCTAssertEqual(ui.currentBadge, "sun.max.fill")

        g.turnOff()
        XCTAssertFalse(g.isHoldingAssertion)
        XCTAssertNil(ui.currentBadge)
        g.stop()
    }

    func testTimerExpiry() throws {
        let g = makeGadget()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        g.now = { clock }
        g.runningBundleIDs = { [] }
        try g.start()
        g.turnOn(minutes: 15)
        XCTAssertTrue(g.isHoldingAssertion)
        clock = clock.addingTimeInterval(15 * 60)
        g.evaluate()
        XCTAssertFalse(g.isHoldingAssertion)
        XCTAssertNil(g.session)
        g.stop()
    }

    func testWatchedAppAndPower() throws {
        let g = makeGadget()
        var running: Set<String> = []
        var onPower = true
        g.runningBundleIDs = { running }
        g.isOnPower = { onPower }
        g.model.settings.watchedApps = [WatchedApp(bundleID: "com.example.render", name: "Render")]
        g.model.settings.onlyOnPower = true
        try g.start()
        XCTAssertFalse(g.isHoldingAssertion)

        running = ["com.example.render"]
        g.evaluate()
        XCTAssertEqual(g.reason, .app(name: "Render"))
        XCTAssertTrue(g.isHoldingAssertion)

        onPower = false
        g.evaluate()
        XCTAssertFalse(g.isHoldingAssertion)
        g.stop()
    }

    func testPostsEventsOnlyOnChange() throws {
        let g = makeGadget()
        g.runningBundleIDs = { [] }
        var log: [String] = []
        let a = events.on(.awakeStarted) { _ in log.append("start") }
        let b = events.on(.awakeEnded) { _ in log.append("end") }
        try g.start()
        g.turnOn(minutes: nil)
        g.evaluate()
        g.evaluate()
        g.turnOff()
        XCTAssertEqual(log, ["start", "end"])
        a.cancel(); b.cancel()
        g.stop()
    }

    /// SCOPE.md §3: "off means off". Switch on/off 100 times; nothing may leak.
    func testStartStopHundredTimesLeavesNothingBehind() throws {
        var settings = AwakeSettings()
        settings.hotkeyEnabled = true
        settings.hotkey = "ctrl+opt+cmd+shift+f9"
        try SettingsStore(directory: dir).save(settings, key: "gadget.awake")

        for _ in 0..<100 {
            let g = makeGadget()
            g.runningBundleIDs = { [] }
            try g.start()
            g.turnOn(minutes: nil)
            XCTAssertTrue(g.isHoldingAssertion)
            g.stop()
            XCTAssertFalse(g.isHoldingAssertion)
        }
        XCTAssertEqual(hotkeys.registeredCount, 0)
        XCTAssertNil(ui.currentBadge)
    }

    func testSettingsPersist() throws {
        let g = makeGadget()
        g.runningBundleIDs = { [] }
        try g.start()
        g.model.settings.keepDisplayOn = false
        // Saving happens on the next main-queue turn.
        let exp = expectation(description: "saved")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        g.stop()
        XCTAssertFalse(makeGadget().model.settings.keepDisplayOn)
    }

    func testMenuShowsStatus() throws {
        let g = makeGadget()
        g.runningBundleIDs = { [] }
        try g.start()
        XCTAssertEqual(g.menuItems().first?.title, "Off")
        g.turnOn(minutes: nil)
        XCTAssertEqual(g.menuItems().first?.title, "On · until turned off")
        XCTAssertTrue(g.menuItems().contains { $0.title == "Turn Off" })
        g.stop()
    }

    /// The picked duration is ticked, and only that one.
    func testMenuTicksTheRunningDuration() throws {
        let g = makeGadget()
        g.runningBundleIDs = { [] }
        try g.start()
        func ticked() -> [String] {
            let sub = g.menuItems().first { $0.title == "Keep Awake For" }?.submenu?.items ?? []
            return sub.filter { $0.state == .on }.map(\.title)
        }
        XCTAssertEqual(ticked(), [], "nothing ticked while off")
        g.turnOn(minutes: 15)
        XCTAssertEqual(ticked(), ["15 minutes"])
        g.turnOn(minutes: nil)
        XCTAssertEqual(ticked(), ["Until turned off"])
        g.turnOff()
        XCTAssertEqual(ticked(), [])
        g.stop()
    }
}
