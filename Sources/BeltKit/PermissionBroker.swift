import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

public enum PermissionStatus: Equatable {
    case granted
    case notGranted
    /// macOS has no public way to check this one; the gadget finds out when it tries.
    case unknown
}

/// Checks and requests system permissions. Gadgets call `request` only when switched on.
@MainActor
public final class PermissionBroker {
    public init() {}

    public func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .unknown
            default: return .notGranted
            }
        case .pasteboard:
            guard #available(macOS 15.4, *) else { return .granted }
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .granted
            case .alwaysDeny: return .notGranted
            default: return .unknown  // macOS asks on the first read
            }
        case .systemAudioRecording, .fullDiskAccess, .automation:
            return .unknown
        }
    }

    /// Shows the system prompt where macOS has one; otherwise opens the right Settings pane.
    public func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .systemAudioRecording, .fullDiskAccess, .automation, .pasteboard:
            openSettings(permission)
        }
    }

    public func openSettings(_ permission: Permission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
