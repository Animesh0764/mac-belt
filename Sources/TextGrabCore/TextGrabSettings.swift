import Foundation

public struct TextGrabSettings: Codable, Equatable, Sendable {
    public var hotkeyEnabled = true
    public var hotkey = "ctrl+opt+t"
    /// Keep the text's line breaks. Off: each paragraph becomes one line.
    public var keepLineBreaks = true
    /// Also read QR codes and barcodes in the box.
    public var readCodes = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextGrabSettings()
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        keepLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .keepLineBreaks) ?? d.keepLineBreaks
        readCodes = try c.decodeIfPresent(Bool.self, forKey: .readCodes) ?? d.readCodes
    }
}
