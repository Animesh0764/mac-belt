// swift-tools-version:5.10
import PackageDescription

// Mac Belt: one menu bar app, many small "gadgets".
// Rule: a fresh clone must build with only the Xcode Command Line Tools / Xcode.
// No third-party packages, no dependencies on sibling folders.
let package = Package(
    name: "MacBelt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacBelt", targets: ["MacBeltApp"]),
    ],
    targets: [
        // Shared plumbing every gadget uses: protocol, registry, settings, hotkeys,
        // permissions, event bus, toast/badge UI, closure menu items.
        .target(name: "BeltKit"),

        // ── Awake ─────────────────────────────────────────────────────────────
        // Pure logic + the IOKit power assertion wrapper. No AppKit → unit-testable.
        .target(name: "AwakeCore"),
        .target(name: "AwakeGadget", dependencies: ["BeltKit", "AwakeCore"], path: "Sources/Gadgets/Awake"),

        // ── Clipboard ─────────────────────────────────────────────────────────
        // Secret detection, SQLite history store, secret shelf. No AppKit.
        .target(name: "ClipboardCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ClipboardGadget", dependencies: ["BeltKit", "ClipboardCore"], path: "Sources/Gadgets/Clipboard"),

        // ── Mic mute ──────────────────────────────────────────────────────────
        .target(name: "MicMuteCore"),
        .target(name: "MicMuteGadget", dependencies: ["BeltKit", "MicMuteCore"], path: "Sources/Gadgets/MicMute"),

        // ── Drop shelf ────────────────────────────────────────────────────────
        .target(name: "ShelfCore"),
        .target(name: "ShelfGadget", dependencies: ["BeltKit", "ShelfCore"], path: "Sources/Gadgets/Shelf"),

        // ── Text grab ─────────────────────────────────────────────────────────
        // Turning OCR lines into pasteable text. No AppKit, no Vision.
        .target(name: "TextGrabCore"),
        .target(name: "TextGrabGadget", dependencies: ["BeltKit", "TextGrabCore"], path: "Sources/Gadgets/TextGrab"),

        // The menu bar app: status item, gallery, settings, support window.
        .executableTarget(name: "MacBeltApp",
                          dependencies: ["BeltKit", "AwakeGadget", "ClipboardGadget", "MicMuteGadget", "ShelfGadget", "TextGrabGadget"]),

        .testTarget(name: "BeltKitTests", dependencies: ["BeltKit"]),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore"]),
        .testTarget(name: "AwakeGadgetTests", dependencies: ["AwakeGadget", "AwakeCore", "BeltKit"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardGadgetTests", dependencies: ["ClipboardGadget", "ClipboardCore", "BeltKit"]),
        .testTarget(name: "MicMuteTests", dependencies: ["MicMuteGadget", "MicMuteCore", "BeltKit"]),
        .testTarget(name: "ShelfTests", dependencies: ["ShelfGadget", "ShelfCore", "BeltKit"]),
        .testTarget(name: "TextGrabTests", dependencies: ["TextGrabGadget", "TextGrabCore", "BeltKit"]),
    ]
)
