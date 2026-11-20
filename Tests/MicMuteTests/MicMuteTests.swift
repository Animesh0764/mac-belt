import AppKit
import XCTest
@testable import BeltKit
@testable import MicMuteCore
@testable import MicMuteGadget

/// A pretend microphone, so tests never touch your real one.
final class FakeMic: MicDevice {
    let uid: String
    let name: String
    let canMute: Bool
    let canSetVolume: Bool
    var isMuted = false
    var volume: Float = 0.6

    init(_ uid: String, canMute: Bool = true, canSetVolume: Bool = true) {
        self.uid = uid
        self.name = uid.capitalized
        self.canMute = canMute
        self.canSetVolume = canSetVolume
    }
}

final class MicControllerTests: XCTestCase {
    func testMuteSwitch() throws {
        let mic = FakeMic("builtin")
        let c = MicController(device: mic)
        XCTAssertFalse(c.muted)
        XCTAssertTrue(try c.toggle())
        XCTAssertTrue(mic.isMuted)
        XCTAssertEqual(mic.volume, 0.6, "mute switch used, volume untouched")
        XCTAssertFalse(try c.toggle())
        XCTAssertFalse(mic.isMuted)
    }

    func testVolumeFallbackRestoresOldVolume() throws {
        let mic = FakeMic("usb", canMute: false)
        mic.volume = 0.42
        let c = MicController(device: mic)
        try c.setMuted(true)
        XCTAssertEqual(mic.volume, 0)
        XCTAssertTrue(c.muted)
        try c.setMuted(false)
        XCTAssertEqual(mic.volume, 0.42, accuracy: 0.0001)
    }

    func testVolumeFallbackWhenAlreadyAtZeroUsesSensibleLevel() throws {
        let mic = FakeMic("usb", canMute: false)
        mic.volume = 0
        let c = MicController(device: mic)
        XCTAssertTrue(c.muted, "volume 0 counts as muted")
        try c.setMuted(false)
        XCTAssertEqual(mic.volume, MicController.fallbackVolume)
    }

    func testUnmutableDevice() {
        let c = MicController(device: FakeMic("weird", canMute: false, canSetVolume: false))
        XCTAssertThrowsError(try c.setMuted(true)) { XCTAssertEqual($0 as? MicError, .cannotMute("Weird")) }
        XCTAssertFalse(c.muted)
        XCTAssertThrowsError(try MicController(device: nil).setMuted(true)) { XCTAssertEqual($0 as? MicError, .noDevice) }
    }

    func testMuteFollowsYouToANewMic() throws {
        let builtin = FakeMic("builtin")
        let airpods = FakeMic("airpods")
        let c = MicController(device: builtin)
        try c.setMuted(true)
        c.deviceChanged(to: airpods)
        XCTAssertTrue(airpods.isMuted, "new mic muted")
        XCTAssertFalse(builtin.isMuted, "old mic put back")
        XCTAssertTrue(c.muted)
        try c.setMuted(false)
        XCTAssertFalse(airpods.isMuted)
    }

    func testSwitchingWhileUnmutedJustReadsNewState() {
        let a = FakeMic("a"), b = FakeMic("b")
        b.isMuted = true  // muted elsewhere
        let c = MicController(device: a)
        c.deviceChanged(to: b)
        XCTAssertTrue(c.muted)
        XCTAssertFalse(c.mutedByUs)
        c.restore()
        XCTAssertTrue(b.isMuted, "never unmutes something muted elsewhere")
    }

    func testMicDisappears() throws {
        let a = FakeMic("a")
        let c = MicController(device: a)
        try c.setMuted(true)
        c.deviceChanged(to: nil)
        XCTAssertFalse(c.muted)
        XCTAssertFalse(a.isMuted)
    }

    func testExternalChangesAreFollowed() throws {
        let mic = FakeMic("builtin")
        let c = MicController(device: mic)
        try c.setMuted(true)
        mic.isMuted = false           // unmuted in System Settings
        c.syncFromDevice()
        XCTAssertFalse(c.muted)
        mic.isMuted = true            // muted by the headset button
        c.syncFromDevice()
        XCTAssertTrue(c.muted)
        XCTAssertFalse(c.mutedByUs)
    }

    func testRestoreOnlyUndoesOurMute() throws {
        let mic = FakeMic("builtin")
        let c = MicController(device: mic)
        try c.setMuted(true)
        c.restore()
        XCTAssertFalse(mic.isMuted)
        XCTAssertFalse(c.muted)
    }

    func testSettingsDecodeOldFile() throws {
        let s = try JSONDecoder().decode(MicMuteSettings.self, from: Data(#"{"showIndicator": false}"#.utf8))
        XCTAssertFalse(s.showIndicator)
        XCTAssertEqual(s.hotkey, "ctrl+opt+m")
        XCTAssertTrue(s.indicatorAtTop)
    }
}

@MainActor
final class MicMuteGadgetTests: XCTestCase {
    private var dir: URL!
    private var ui: BeltUI!
    private var events: EventBus!
    private var hotkeys: HotkeyCenter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macbelt-mic-\(UUID().uuidString)")
        ui = BeltUI()
        ui.toastsEnabled = false
        events = EventBus()
        hotkeys = HotkeyCenter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGadget(mic: FakeMic?, hotkey: String? = nil) throws -> MicMuteGadget {
        var s = MicMuteSettings()
        s.showIndicator = false  // no window during tests
        if let hotkey { s.hotkey = hotkey } else { s.hotkeyEnabled = false }
        let store = SettingsStore(directory: dir)
        try store.save(s, key: "gadget.mic-mute")
        let ctx = GadgetContext(id: "mic-mute", store: store, hotkeys: hotkeys, permissions: PermissionBroker(),
                                events: events, ui: ui)
        let g = MicMuteGadget(context: ctx)
        g.deviceProvider = { mic }
        g.listensToCoreAudio = false
        return g
    }

    func testToggleBadgeEventsAndMenu() throws {
        let mic = FakeMic("builtin")
        let g = try makeGadget(mic: mic)
        var log: [String] = []
        let a = events.on(.micMuted) { _ in log.append("muted") }
        let b = events.on(.micUnmuted) { _ in log.append("unmuted") }
        try g.start()
        XCTAssertEqual(g.menuItems().first?.title, "Mic on · Builtin")

        g.toggle()
        XCTAssertTrue(mic.isMuted)
        XCTAssertEqual(ui.currentBadge, "mic.slash.fill")
        XCTAssertEqual(g.menuItems().first?.title, "Muted · Builtin")
        XCTAssertTrue(g.menuItems().contains { $0.title.hasPrefix("Unmute") })

        g.toggle()
        XCTAssertFalse(mic.isMuted)
        XCTAssertNil(ui.currentBadge)
        XCTAssertEqual(log, ["muted", "unmuted"])
        a.cancel(); b.cancel()
        g.stop()
    }

    func testMutedBadgeBeatsAwakeBadge() throws {
        let g = try makeGadget(mic: FakeMic("builtin"))
        try g.start()
        ui.setBadge("sun.max.fill", for: "awake")
        g.setMuted(true)
        XCTAssertEqual(ui.currentBadge, "mic.slash.fill")
        g.setMuted(false)
        XCTAssertEqual(ui.currentBadge, "sun.max.fill")
        g.stop()
    }

    func testStoppingUnmutes() throws {
        let mic = FakeMic("builtin")
        let g = try makeGadget(mic: mic)
        try g.start()
        g.setMuted(true)
        g.stop()
        XCTAssertFalse(mic.isMuted, "never leave the mic muted with no sign on screen")
        XCTAssertNil(ui.currentBadge)
    }

    func testDeviceSwitchKeepsYouMuted() throws {
        let builtin = FakeMic("builtin"), airpods = FakeMic("airpods")
        var current: FakeMic = builtin
        let g = try makeGadget(mic: nil)
        g.deviceProvider = { current }
        try g.start()
        g.setMuted(true)
        current = airpods
        g.defaultDeviceChanged()
        XCTAssertTrue(airpods.isMuted)
        XCTAssertFalse(builtin.isMuted)
        XCTAssertTrue(g.menuItems().first!.title.contains("Airpods"))
        g.stop()
    }

    func testNoMicrophone() throws {
        let g = try makeGadget(mic: nil)
        try g.start()
        g.toggle()  // must not crash
        XCTAssertEqual(g.menuItems().first?.title, "No microphone found")
        g.stop()
    }

    func testStartStopHundredTimesLeavesNothingBehind() throws {
        let mic = FakeMic("builtin")
        _ = try makeGadget(mic: mic, hotkey: "ctrl+opt+cmd+shift+f7")
        for _ in 0..<100 {
            let ctx = GadgetContext(id: "mic-mute", store: SettingsStore(directory: dir), hotkeys: hotkeys,
                                    permissions: PermissionBroker(), events: events, ui: ui)
            let g = MicMuteGadget(context: ctx)
            g.deviceProvider = { mic }
            g.listensToCoreAudio = false
            try g.start()
            g.setMuted(true)
            XCTAssertEqual(hotkeys.registeredCount, 1)
            g.stop()
        }
        XCTAssertEqual(hotkeys.registeredCount, 0)
        XCTAssertFalse(mic.isMuted)
        XCTAssertNil(ui.currentBadge)
    }
}

/// Read-only checks against the real default microphone. Never changes mute or volume.
final class CoreAudioMicReadOnlyTests: XCTestCase {
    func testReadsDefaultInput() throws {
        guard let mic = CoreAudioMic.defaultInput() else {
            throw XCTSkip("no input device on this Mac")
        }
        XCTAssertFalse(mic.name.isEmpty)
        XCTAssertFalse(mic.uid.isEmpty)
        let before = (mic.isMuted, mic.volume)
        XCTAssertTrue(MicController.canMute(mic), "\(mic.name): canMute=\(mic.canMute) canSetVolume=\(mic.canSetVolume)")
        XCTAssertEqual(before.0, mic.isMuted)
        XCTAssertEqual(before.1, mic.volume)
        print("default input: \(mic.name) · mute switch: \(mic.canMute) · volume control: \(mic.canSetVolume)")
    }
}
