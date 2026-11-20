import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut such as "ctrl+opt+cmd+a".
public struct HotkeySpec: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    public let modifiers: UInt32
    public let key: String

    /// Parses strings like "ctrl+opt+cmd+a", "cmd+shift+2", "ctrl+space", "f5".
    /// Accepts ctrl/control/⌃, opt/option/alt/⌥, cmd/command/⌘, shift/⇧.
    public init?(_ string: String) {
        let parts = string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let keyPart = parts.last, let code = Self.keyCodes[keyPart] else { return nil }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": mods |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥": mods |= UInt32(optionKey)
            case "cmd", "command", "⌘": mods |= UInt32(cmdKey)
            case "shift", "⇧": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        // A bare letter or digit would fire while typing; require a modifier unless it's an F-key.
        if mods == 0 && !keyPart.hasPrefix("f") { return nil }
        if mods == 0 && keyPart == "f" { return nil }
        self.keyCode = code
        self.modifiers = mods
        self.key = keyPart
    }

    /// "⌃⌥⌘A"
    public var description: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        switch key {
        case "space": s += "Space"
        case "return": s += "↩"
        case "escape": s += "⎋"
        case "tab": s += "⇥"
        default: s += key.uppercased()
        }
        return s
    }

    static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "space": 49, "return": 36, "tab": 48, "escape": 53,
        ]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fKeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()
}

/// System-wide shortcuts via Carbon `RegisterEventHotKey`.
/// Unlike a global NSEvent monitor this needs no Accessibility / Input Monitoring permission.
@MainActor
public final class HotkeyCenter {
    public enum RegisterError: Error, Equatable {
        /// Another gadget in Mac Belt already uses this shortcut.
        case usedByGadget(String)
        /// macOS refused it, usually because another app already owns it.
        case rejectedBySystem
    }

    private struct Entry {
        let owner: String
        let spec: HotkeySpec
        let ref: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    fileprivate static weak var shared: HotkeyCenter?

    public init() {}

    /// Register a shortcut. Keep the returned registration and call `unregister()` in `stop()`.
    public func register(_ spec: HotkeySpec, owner: String,
                         handler: @escaping @MainActor () -> Void) -> Result<Registration, RegisterError> {
        if let clash = entries.values.first(where: { $0.spec == spec }) {
            return .failure(.usedByGadget(clash.owner))
        }
        installHandlerOnce()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4245_4C54), id: id)  // 'BELT'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return .failure(.rejectedBySystem) }
        entries[id] = Entry(owner: owner, spec: spec, ref: ref, handler: handler)
        return .success(Registration(center: self, id: id))
    }

    public var registeredCount: Int { entries.count }

    fileprivate func unregister(id: UInt32) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    fileprivate func fire(id: UInt32) {
        entries[id]?.handler()
    }

    private func installHandlerOnce() {
        guard eventHandler == nil else { return }
        HotkeyCenter.shared = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared?.fire(id: id) }
            }
            return noErr
        }, 1, &type, nil, &eventHandler)
    }

    @MainActor
    public final class Registration {
        private weak var center: HotkeyCenter?
        private let id: UInt32

        fileprivate init(center: HotkeyCenter, id: UInt32) {
            self.center = center
            self.id = id
        }

        public func unregister() {
            center?.unregister(id: id)
            center = nil
        }
    }
}
