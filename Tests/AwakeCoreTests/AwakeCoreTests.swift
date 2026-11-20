import XCTest
@testable import AwakeCore

final class AwakeLogicTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let xcode = WatchedApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")

    func testOffByDefault() {
        XCTAssertNil(AwakeLogic.decide(session: nil, runningWatchedApps: [], onPower: true,
                                       settings: AwakeSettings(), now: t0))
    }

    func testTimedSessionLastsUntilEnd() {
        let s = AwakeLogic.session(minutes: 15, now: t0)
        XCTAssertEqual(s.endsAt, t0.addingTimeInterval(900))
        XCTAssertEqual(AwakeLogic.decide(session: s, runningWatchedApps: [], onPower: true,
                                         settings: AwakeSettings(), now: t0.addingTimeInterval(899)),
                       .manual(endsAt: s.endsAt))
        XCTAssertNil(AwakeLogic.decide(session: s, runningWatchedApps: [], onPower: true,
                                       settings: AwakeSettings(), now: t0.addingTimeInterval(900)))
        XCTAssertTrue(AwakeLogic.isExpired(s, now: t0.addingTimeInterval(900)))
    }

    func testIndefiniteSessionNeverExpires() {
        let s = AwakeLogic.session(minutes: nil, now: t0)
        XCTAssertNil(s.endsAt)
        XCTAssertFalse(AwakeLogic.isExpired(s, now: t0.addingTimeInterval(86_400 * 30)))
    }

    func testWatchedAppKeepsAwake() {
        XCTAssertEqual(AwakeLogic.decide(session: nil, runningWatchedApps: [xcode], onPower: true,
                                         settings: AwakeSettings(), now: t0), .app(name: "Xcode"))
    }

    func testManualSessionWinsOverApp() {
        let s = AwakeLogic.session(minutes: 60, now: t0)
        XCTAssertEqual(AwakeLogic.decide(session: s, runningWatchedApps: [xcode], onPower: true,
                                         settings: AwakeSettings(), now: t0), .manual(endsAt: s.endsAt))
    }

    func testOnlyOnPowerBlocksEverythingOnBattery() {
        var settings = AwakeSettings()
        settings.onlyOnPower = true
        let s = AwakeLogic.session(minutes: nil, now: t0)
        XCTAssertNil(AwakeLogic.decide(session: s, runningWatchedApps: [xcode], onPower: false,
                                       settings: settings, now: t0))
        XCTAssertNotNil(AwakeLogic.decide(session: s, runningWatchedApps: [], onPower: true,
                                          settings: settings, now: t0))
    }

    func testRemainingText() {
        func text(_ seconds: TimeInterval) -> String {
            AwakeLogic.remainingText(until: t0.addingTimeInterval(seconds), now: t0)
        }
        XCTAssertEqual(text(30), "less than a minute left")
        XCTAssertEqual(text(60), "1 min left")
        XCTAssertEqual(text(61), "2 min left", "rounds up so it never says 0")
        XCTAssertEqual(text(47 * 60), "47 min left")
        XCTAssertEqual(text(3600), "1 h left")
        XCTAssertEqual(text(65 * 60), "1 h 5 min left")
    }

    func testLabels() {
        XCTAssertEqual(AwakeLogic.durationLabel(minutes: nil), "Until turned off")
        XCTAssertEqual(AwakeLogic.durationLabel(minutes: 15), "15 minutes")
        XCTAssertEqual(AwakeLogic.durationLabel(minutes: 60), "1 hour")
        XCTAssertEqual(AwakeLogic.durationLabel(minutes: 480), "8 hours")
        XCTAssertEqual(AwakeLogic.durationLabel(minutes: 90), "1 hour 30 min")
        XCTAssertEqual(AwakeLogic.statusText(nil, now: t0), "Off")
        XCTAssertEqual(AwakeLogic.statusText(.app(name: "Zoom"), now: t0), "On · while Zoom is running")
        XCTAssertEqual(AwakeLogic.statusText(.manual(endsAt: nil), now: t0), "On · until turned off")
    }

    func testSettingsDecodeOldFileWithMissingFields() throws {
        let json = #"{"keepDisplayOn": false, "watchedApps": [{"bundleID":"a.b","name":"AB"}]}"#
        let s = try JSONDecoder().decode(AwakeSettings.self, from: Data(json.utf8))
        XCTAssertFalse(s.keepDisplayOn)
        XCTAssertEqual(s.watchedApps.map(\.name), ["AB"])
        XCTAssertFalse(s.onlyOnPower)
        XCTAssertEqual(s.hotkey, "ctrl+opt+cmd+a")
        XCTAssertNil(s.defaultMinutes)
    }
}

/// Talks to the real power manager: checks that the assertion actually shows up
/// in `pmset -g assertions`, and that it's gone after release.
final class PowerAssertionTests: XCTestCase {
    private func pmsetListsAssertion(_ name: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains(name)
    }

    func testHoldSwitchAndRelease() throws {
        let name = "MacBelt test \(UUID().uuidString.prefix(8))"
        let a = PowerAssertion(name: name)
        XCTAssertFalse(a.isHeld)
        XCTAssertTrue(a.hold(.display))
        XCTAssertEqual(a.kind, .display)
        XCTAssertTrue(try pmsetListsAssertion(name))
        XCTAssertTrue(a.hold(.system))
        XCTAssertEqual(a.kind, .system)
        a.release()
        XCTAssertFalse(a.isHeld)
        XCTAssertFalse(try pmsetListsAssertion(name))
    }

    func testDeinitReleases() throws {
        let name = "MacBelt deinit \(UUID().uuidString.prefix(8))"
        do {
            let a = PowerAssertion(name: name)
            a.hold(.display)
            XCTAssertTrue(try pmsetListsAssertion(name))
        }
        XCTAssertFalse(try pmsetListsAssertion(name))
    }

    func testPowerSourceDoesNotCrash() {
        _ = PowerSource.isOnAC()
    }
}
