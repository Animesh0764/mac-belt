import Foundation

/// An app that keeps the Mac awake while it's running.
public struct WatchedApp: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct AwakeSettings: Codable, Equatable, Sendable {
    /// true: keep the screen on too. false: let the screen sleep, but keep the Mac running.
    public var keepDisplayOn = true
    /// Only stay awake while on AC power (laptops).
    public var onlyOnPower = false
    public var watchedApps: [WatchedApp] = []
    public var hotkeyEnabled = false
    public var hotkey = "ctrl+opt+cmd+a"
    /// What the hotkey / "Turn On" uses. nil = until turned off.
    public var defaultMinutes: Int?

    public init() {}

    // decodeIfPresent everywhere so adding a field never wipes someone's settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AwakeSettings()
        keepDisplayOn = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? d.keepDisplayOn
        onlyOnPower = try c.decodeIfPresent(Bool.self, forKey: .onlyOnPower) ?? d.onlyOnPower
        watchedApps = try c.decodeIfPresent([WatchedApp].self, forKey: .watchedApps) ?? d.watchedApps
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes)
    }
}

/// A manual "keep awake" the user started from the menu or hotkey.
public struct AwakeSession: Equatable, Sendable {
    public var startedAt: Date
    /// nil = until turned off.
    public var endsAt: Date?
    /// The duration the user picked (nil = until turned off). Used to tick it in the menu.
    public var minutes: Int?

    public init(startedAt: Date, endsAt: Date?, minutes: Int? = nil) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.minutes = minutes
    }
}

/// Why the Mac is being kept awake right now.
public enum AwakeReason: Equatable, Sendable {
    case manual(endsAt: Date?)
    case app(name: String)
}

public enum AwakeLogic {
    public static let durationChoices: [Int] = [15, 30, 60, 120, 180, 480]

    public static func session(minutes: Int?, now: Date) -> AwakeSession {
        AwakeSession(startedAt: now, endsAt: minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
                     minutes: minutes)
    }

    public static func isExpired(_ session: AwakeSession, now: Date) -> Bool {
        guard let end = session.endsAt else { return false }
        return now >= end
    }

    /// The single decision: should the Mac be kept awake right now, and why?
    /// A manual session wins over a watched app, so the menu shows the time left.
    public static func decide(session: AwakeSession?, runningWatchedApps: [WatchedApp],
                              onPower: Bool, settings: AwakeSettings, now: Date) -> AwakeReason? {
        if settings.onlyOnPower && !onPower { return nil }
        if let session, !isExpired(session, now: now) {
            return .manual(endsAt: session.endsAt)
        }
        if let app = runningWatchedApps.first {
            return .app(name: app.name)
        }
        return nil
    }

    /// "47 min left", "1 h 5 min left", "2 h left", "less than a minute left".
    public static func remainingText(until end: Date, now: Date) -> String {
        let seconds = end.timeIntervalSince(now)
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min left" }
        if m == 0 { return "\(h) h left" }
        return "\(h) h \(m) min left"
    }

    /// "15 minutes", "1 hour", "8 hours", "Until turned off".
    public static func durationLabel(minutes: Int?) -> String {
        guard let minutes else { return "Until turned off" }
        if minutes < 60 { return "\(minutes) minutes" }
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return m == 0 ? hours : "\(hours) \(m) min"
    }

    /// One line for the menu: "On · 47 min left", "On · while Xcode is running", "Off".
    public static func statusText(_ reason: AwakeReason?, now: Date) -> String {
        switch reason {
        case nil: return "Off"
        case .manual(nil): return "On · until turned off"
        case .manual(let end?): return "On · \(remainingText(until: end, now: now))"
        case .app(let name): return "On · while \(name) is running"
        }
    }
}
