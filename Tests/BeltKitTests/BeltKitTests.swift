import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import BeltKit

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    struct Sample: Codable, Equatable { var a = 1; var b = "x" }

    func testMissingFileReturnsDefault() {
        let store = SettingsStore(directory: dir)
        XCTAssertEqual(store.load(Sample.self, key: "nope", default: Sample(a: 7)), Sample(a: 7))
    }

    func testRoundTripCreatesFolder() throws {
        let store = SettingsStore(directory: dir)
        try store.save(Sample(a: 3, b: "hi"), key: "s")
        XCTAssertEqual(store.load(Sample.self, key: "s", default: Sample()), Sample(a: 3, b: "hi"))
        let text = try String(contentsOf: store.url(for: "s"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"a\" : 3"), "settings should be human-readable JSON: \(text)")
    }

    func testCorruptFileReturnsDefault() throws {
        let store = SettingsStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url(for: "s"))
        XCTAssertEqual(store.load(Sample.self, key: "s", default: Sample()), Sample())
    }

    func testAppStateToleratesMissingFields() throws {
        let store = SettingsStore(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"enabledGadgets":["awake"]}"#.utf8).write(to: store.url(for: "app"))
        let state = store.load(AppState.self, key: "app", default: AppState())
        XCTAssertEqual(state.enabledGadgets, ["awake"])
        XCTAssertFalse(state.onboardingDone)
    }
}

final class HotkeySpecTests: XCTestCase {
    func testParsesModifiersAndKey() throws {
        let spec = try XCTUnwrap(HotkeySpec("ctrl+opt+cmd+a"))
        XCTAssertEqual(spec.keyCode, 0)
        XCTAssertEqual(spec.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(spec.description, "⌃⌥⌘A")
    }

    func testAliasesAndSpacing() {
        XCTAssertEqual(HotkeySpec("Command + Shift + 2"), HotkeySpec("cmd+shift+2"))
        XCTAssertEqual(HotkeySpec("⌃+⌥+k"), HotkeySpec("control+option+k"))
        XCTAssertEqual(HotkeySpec("ctrl+space")?.description, "⌃Space")
    }

    func testFunctionKeysNeedNoModifier() {
        XCTAssertEqual(HotkeySpec("f5")?.keyCode, 96)
        XCTAssertEqual(HotkeySpec("f12")?.keyCode, 111)
    }

    func testRejectsBadInput() {
        XCTAssertNil(HotkeySpec(""))
        XCTAssertNil(HotkeySpec("a"), "a bare letter would fire while typing")
        XCTAssertNil(HotkeySpec("f"), "plain 'f' is a letter, not an F-key")
        XCTAssertNil(HotkeySpec("ctrl+hyper+a"))
        XCTAssertNil(HotkeySpec("ctrl+"))
        XCTAssertNil(HotkeySpec("ctrl+é"))
    }

    func testCodable() throws {
        let spec = try XCTUnwrap(HotkeySpec("cmd+opt+m"))
        let data = try JSONEncoder().encode(spec)
        XCTAssertEqual(try JSONDecoder().decode(HotkeySpec.self, from: data), spec)
    }
}

@MainActor
final class EventBusTests: XCTestCase {
    func testPostReachesSubscribersAndCancelStops() {
        let bus = EventBus()
        var got: [String] = []
        let sub = bus.on(.micMuted) { info in got.append(info["by"] ?? "?") }
        bus.post(.micMuted, info: ["by": "hotkey"])
        bus.post(.micUnmuted)
        XCTAssertEqual(got, ["hotkey"])
        sub.cancel()
        bus.post(.micMuted, info: ["by": "again"])
        XCTAssertEqual(got, ["hotkey"])
        XCTAssertEqual(bus.subscriberCount(.micMuted), 0)
    }
}

@MainActor
final class BeltUITests: XCTestCase {
    func testBadgeIsStableAndNotifies() {
        let ui = BeltUI()
        var changes = 0
        ui.onBadgeChange = { changes += 1 }
        ui.setBadge("b.circle", for: "zeta")
        ui.setBadge("a.circle", for: "alpha")
        ui.setBadge("a.circle", for: "alpha")  // no change → no callback
        XCTAssertEqual(ui.currentBadge, "a.circle")
        XCTAssertEqual(changes, 2)
        ui.setBadge(nil, for: "alpha")
        XCTAssertEqual(ui.currentBadge, "b.circle")
    }
}

// MARK: - Registry

@MainActor
final class FakeGadget: Gadget {
    static var info = GadgetInfo(id: "fake", name: "Fake", symbol: "star", summary: "test")
    static var failStart = false
    static var started = 0
    static var stopped = 0
    init(context: GadgetContext) {}
    func start() throws {
        if Self.failStart { throw GadgetError("nope") }
        Self.started += 1
    }
    func stop() { Self.stopped += 1 }
    func menuItems() -> [NSMenuItem] { [] }
}

@MainActor
final class GadgetRegistryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-reg-\(UUID().uuidString)")
        FakeGadget.failStart = false
        FakeGadget.started = 0
        FakeGadget.stopped = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeRegistry() -> GadgetRegistry {
        let store = SettingsStore(directory: dir)
        let hotkeys = HotkeyCenter(), perms = PermissionBroker(), events = EventBus(), ui = BeltUI()
        ui.toastsEnabled = false
        return GadgetRegistry(types: [FakeGadget.self], store: store) { info in
            GadgetContext(id: info.id, store: store, hotkeys: hotkeys, permissions: perms, events: events, ui: ui)
        }
    }

    func testEnableDisablePersists() {
        let r = makeRegistry()
        XCTAssertTrue(r.setEnabled("fake", true))
        XCTAssertTrue(r.isRunning("fake"))
        XCTAssertEqual(FakeGadget.started, 1)

        // A new registry (next launch) starts it again.
        let r2 = makeRegistry()
        XCTAssertTrue(r2.isEnabled("fake"))
        r2.startEnabledAtLaunch()
        XCTAssertTrue(r2.isRunning("fake"))

        r2.setEnabled("fake", false)
        XCTAssertFalse(r2.isRunning("fake"))
        XCTAssertFalse(makeRegistry().isEnabled("fake"))
    }

    func testFailedStartStaysOffWithError() {
        FakeGadget.failStart = true
        let r = makeRegistry()
        XCTAssertFalse(r.setEnabled("fake", true))
        XCTAssertFalse(r.isRunning("fake"))
        XCTAssertFalse(r.isEnabled("fake"))
        XCTAssertEqual(r.errors["fake"], "nope")
        XCTAssertEqual(FakeGadget.stopped, 1, "a failed start must still clean up")
    }

    func testCrashWhileStartingSwitchesGadgetOffNextLaunch() throws {
        // Simulate: app.json says "fake" was starting when the app died.
        var state = AppState()
        state.enabledGadgets = ["fake"]
        state.startingGadget = "fake"
        try SettingsStore(directory: dir).save(state, key: "app")

        let r = makeRegistry()
        XCTAssertEqual(r.startEnabledAtLaunch(), ["Fake"])
        XCTAssertFalse(r.isRunning("fake"))
        XCTAssertFalse(r.isEnabled("fake"))
        XCTAssertNotNil(r.errors["fake"])
        XCTAssertNil(makeRegistry().state.startingGadget)
    }

    func testStopAll() {
        let r = makeRegistry()
        r.setEnabled("fake", true)
        r.stopAll()
        XCTAssertFalse(r.isRunning("fake"))
        XCTAssertTrue(r.isEnabled("fake"), "quitting the app doesn't switch gadgets off")
    }
}

@MainActor
final class ToastLayoutTests: XCTestCase {
    /// The pill must be at least as wide as its text on one line (no "…" truncation).
    func testToastFitsItsText() {
        for text in ["Copied", "Copies from Wispr Flow will be saved again", "History paused · new copies won't be saved"] {
            let host = NSHostingView(rootView: ToastView(text: text, symbol: "eye"))
            let textWidth = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]).width
            // 18+18 horizontal padding, 16+16 outer padding, 8 spacing, ~16 icon.
            XCTAssertGreaterThanOrEqual(host.fittingSize.width, textWidth + 36 + 32 + 8 + 14, text)
            XCTAssertLessThan(host.fittingSize.height, 80, "one line: \(text)")
        }
    }
}
