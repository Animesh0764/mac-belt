import Foundation

/// A microphone (input device) that can be muted. The real one is Core Audio; tests use a fake.
public protocol MicDevice: AnyObject {
    var uid: String { get }
    var name: String { get }
    /// The device has a mute switch (most built-in and USB mics).
    var canMute: Bool { get }
    var isMuted: Bool { get set }
    /// The device has an input volume we can set (fallback when there's no mute switch).
    var canSetVolume: Bool { get }
    /// 0...1
    var volume: Float { get set }
}

public enum MicError: Error, Equatable, CustomStringConvertible {
    case noDevice
    case cannotMute(String)

    public var description: String {
        switch self {
        case .noDevice: return "No microphone found"
        case .cannotMute(let name): return "\(name) can't be muted"
        }
    }
}

/// Muting logic, independent of Core Audio.
///
/// - Uses the device's mute switch when it has one; otherwise sets its input volume to 0
///   and remembers the old volume to restore.
/// - "Muted" follows you across devices: if the default mic changes while muted (AirPods
///   connect), the new mic is muted and the old one is put back the way it was.
/// - Only undoes mutes it made itself (`mutedByUs`), so it never unmutes something you
///   muted elsewhere.
public final class MicController {
    public private(set) var device: MicDevice?
    public private(set) var muted = false
    /// True when Mac Belt muted the current device (so stopping should unmute it).
    public private(set) var mutedByUs = false
    /// Device uid → input volume before we set it to 0.
    private var savedVolumes: [String: Float] = [:]
    public static let fallbackVolume: Float = 0.75

    public init(device: MicDevice?) {
        self.device = device
        muted = device.map(Self.readMuted) ?? false
    }

    public static func readMuted(_ d: MicDevice) -> Bool {
        if d.canMute { return d.isMuted }
        if d.canSetVolume { return d.volume <= 0.0001 }
        return false
    }

    public static func canMute(_ d: MicDevice) -> Bool { d.canMute || d.canSetVolume }

    public func setMuted(_ mute: Bool) throws {
        guard let d = device else { throw MicError.noDevice }
        try apply(mute, to: d)
        muted = mute
        mutedByUs = mute
    }

    /// Returns the new state.
    @discardableResult
    public func toggle() throws -> Bool {
        try setMuted(!muted)
        return muted
    }

    /// The default input device changed (or disappeared).
    public func deviceChanged(to new: MicDevice?) {
        let old = device
        guard old?.uid != new?.uid else { return }
        if muted && mutedByUs {
            if let old { try? apply(false, to: old) }
            device = new
            if let new, (try? apply(true, to: new)) != nil {
                muted = true
            } else {
                muted = new.map(Self.readMuted) ?? false
                mutedByUs = false
            }
        } else {
            device = new
            muted = new.map(Self.readMuted) ?? false
            mutedByUs = false
        }
    }

    /// Someone changed mute/volume outside Mac Belt (System Settings, the mic's own button).
    public func syncFromDevice() {
        guard let d = device else { return }
        let now = Self.readMuted(d)
        if now != muted {
            muted = now
            mutedByUs = false
            if !now { savedVolumes[d.uid] = nil }
        }
    }

    /// Undo our mute (gadget switched off / app quitting).
    public func restore() {
        guard muted, mutedByUs, let d = device else { return }
        try? apply(false, to: d)
        muted = false
        mutedByUs = false
    }

    private func apply(_ mute: Bool, to d: MicDevice) throws {
        if d.canMute {
            d.isMuted = mute
            return
        }
        guard d.canSetVolume else { throw MicError.cannotMute(d.name) }
        if mute {
            if d.volume > 0.0001 { savedVolumes[d.uid] = d.volume }
            d.volume = 0
        } else {
            let saved = savedVolumes.removeValue(forKey: d.uid)
            d.volume = saved ?? (d.volume > 0.0001 ? d.volume : Self.fallbackVolume)
        }
    }
}
