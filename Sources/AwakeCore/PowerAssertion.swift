import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Wraps an IOKit power assertion. Holding one stops idle sleep; releasing it lets the Mac
/// sleep normally again. Visible in `pmset -g assertions` under `name`.
public final class PowerAssertion {
    public enum Kind: Equatable, Sendable {
        /// Screen stays on (and so does the Mac).
        case display
        /// Screen may sleep, the Mac keeps running.
        case system

        var ioType: String {
            switch self {
            case .display: return "PreventUserIdleDisplaySleep"
            case .system: return "PreventUserIdleSystemSleep"
            }
        }
    }

    public let name: String
    public private(set) var kind: Kind?
    private var assertionID: IOPMAssertionID = 0

    public init(name: String) {
        self.name = name
    }

    deinit { release() }

    public var isHeld: Bool { kind != nil }

    /// Hold an assertion of `kind`. Replaces a held assertion of the other kind.
    @discardableResult
    public func hold(_ kind: Kind) -> Bool {
        if self.kind == kind { return true }
        release()
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kind.ioType as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 name as CFString, &id)
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        self.kind = kind
        return true
    }

    public func release() {
        guard kind != nil else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        kind = nil
    }
}

public enum PowerSource {
    /// true on AC power, and always on desktops.
    public static func isOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}
