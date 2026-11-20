import AwakeGadget
import ClipboardGadget
import MicMuteGadget
import ShelfGadget
import BeltKit

/// Every gadget, in menu order. Adding a gadget = add its target to Package.swift and one line here.
@MainActor
enum Gadgets {
    static let all: [any Gadget.Type] = [
        AwakeGadget.self,
        ClipboardGadget.self,
        MicMuteGadget.self,
        ShelfGadget.self,
    ]

    /// Switched on at first launch. Only gadgets that need no permissions.
    static let onByDefault: [String] = ["awake"]
}
