# Writing a gadget

A gadget is one small tool. Adding one touches three places:

1. **`Sources/Gadgets/<Name>/<Name>Gadget.swift`**: a class that conforms to `Gadget` (see `Sources/BeltKit/Gadget.swift`).
2. **`Package.swift`**: a target for it (plus a `<Name>Core` target for logic you want to unit-test).
3. **`Sources/MacBeltApp/Gadgets.swift`**: one line in `Gadgets.all`.

Use `Sources/Gadgets/Awake` as the example to copy.

## The contract

```swift
@MainActor
public final class MyGadget: Gadget {
    public static let info = GadgetInfo(
        id: "my-gadget",             // stable forever: it's the settings key
        name: "My Gadget",
        symbol: "sparkles",           // SF Symbol
        summary: "One sentence for the gallery card.",
        replaces: "SomePaidApp",      // optional
        permissions: []               // e.g. [.accessibility]
    )

    public required init(context: GadgetContext) { … }
    public func start() throws { … }     // acquire everything here
    public func stop() { … }             // release EVERYTHING start() acquired
    public func menuItems() -> [NSMenuItem] { … }   // rebuilt each time the menu opens
    public func settingsView() -> AnyView? { … }    // optional
}
```

`context` gives you:

| | |
|---|---|
| `context.settings` | `load(_:default:)` / `save(_:)` a Codable struct (JSON in Application Support) |
| `context.hotkeys` | global shortcuts without Accessibility permission |
| `context.permissions` | check/request permissions |
| `context.events` | talk to other gadgets (`BeltEvent`), never import them |
| `context.toast(_:)` | a small pill at the bottom of the screen |
| `context.setBadge(_:)` | show an SF Symbol in the menu bar icon while active |
| `context.log` | `os.Logger` |

## Rules

- **Off means off.** `stop()` must release timers, observers, hotkeys, event subscriptions, audio objects, file handles. Add a test that starts and stops your gadget 100 times (see `AwakeGadgetTests`).
- **No permission prompts in `init`.** Ask in `start()` at the earliest, ideally right when a feature needs it.
- **Settings structs decode with `decodeIfPresent`**, so adding a field never wipes someone's settings.
- **No network calls** unless the gadget is clearly about the network and says so.
- **No third-party dependencies.** A fresh clone must build with only Apple's tools.
- Put pure logic in a `<Name>Core` target (no AppKit) and test it.

## Before opening a PR

```bash
make test
make run      # try it from the menu bar
```
