import Foundation

public struct MicMuteSettings: Codable, Equatable, Sendable {
    public var hotkeyEnabled = true
    public var hotkey = "ctrl+opt+m"
    /// A "Muted" pill that stays on screen while the mic is muted.
    public var showIndicator = true
    public var indicatorAtTop = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MicMuteSettings()
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        showIndicator = try c.decodeIfPresent(Bool.self, forKey: .showIndicator) ?? d.showIndicator
        indicatorAtTop = try c.decodeIfPresent(Bool.self, forKey: .indicatorAtTop) ?? d.indicatorAtTop
    }
}
