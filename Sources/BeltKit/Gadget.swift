import AppKit
import SwiftUI

/// A system permission a gadget may need. Gadgets declare these in `GadgetInfo`;
/// the app asks for them only when the user switches that gadget on.
public enum Permission: Hashable, Sendable, CustomStringConvertible {
    case accessibility
    case screenRecording
    case systemAudioRecording
    case microphone
    case fullDiskAccess
    /// "Paste from Other Apps" (macOS 15.4+): reading the clipboard in the background.
    case pasteboard
    case automation(bundleID: String)

    public var description: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .systemAudioRecording: return "System Audio Recording"
        case .microphone: return "Microphone"
        case .fullDiskAccess: return "Full Disk Access"
        case .pasteboard: return "Paste from Other Apps"
        case .automation(let id): return "Automation (\(id))"
        }
    }

    /// Deep link into System Settings ▸ Privacy & Security.
    public var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording, .systemAudioRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .automation: anchor = "Privacy_Automation"
        // No documented anchor for "Paste from Other Apps"; open Privacy & Security.
        case .pasteboard: return URL(string: "x-apple.systempreferences:com.apple.preference.security")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

/// Static description of a gadget, shown in the gallery.
public struct GadgetInfo: Sendable {
    /// Stable forever: used as the settings key.
    public let id: String
    public let name: String
    /// SF Symbol name.
    public let symbol: String
    public let summary: String
    /// The paid/popular app it replaces, e.g. "Amphetamine". Shown on the card.
    public let replaces: String?
    public let permissions: Set<Permission>
    public let minimumOS: OperatingSystemVersion

    public init(id: String, name: String, symbol: String, summary: String, replaces: String? = nil,
                permissions: Set<Permission> = [],
                minimumOS: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.replaces = replaces
        self.permissions = permissions
        self.minimumOS = minimumOS
    }

    public var isSupportedOnThisMac: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS)
    }
}

/// One tool on the belt.
///
/// Rules (see SCOPE.md §3):
/// - `stop()` must release everything `start()` acquired: timers, observers, hotkeys,
///   event subscriptions, power assertions, audio objects. Off means off.
/// - Gadgets never import each other; they talk through `context.events`.
@MainActor
public protocol Gadget: AnyObject {
    static var info: GadgetInfo { get }
    init(context: GadgetContext)
    /// Called when the user switches the gadget on, or at launch if it was on.
    func start() throws
    func stop()
    /// Items shown under the gadget's heading in the Mac Belt menu.
    /// Called every time the menu opens, so it can show live state.
    func menuItems() -> [NSMenuItem]
    /// Optional page in Settings.
    func settingsView() -> AnyView?
}

public extension Gadget {
    func settingsView() -> AnyView? { nil }
}

/// Thrown from `start()` when a gadget can't run; the message is shown to the user.
public struct GadgetError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
