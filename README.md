# 🧰 Mac Belt

**Small Mac tools in one menu bar icon. Free and open source. No paid tier, no tracking, no account.**

Mac Belt is a utility belt for your Mac: a set of small "gadgets" you switch on or off. A gadget that's off uses no CPU and asks for no permissions.

```bash
git clone https://github.com/Animesh0764/mac-belt.git && cd mac-belt && make install
```

Needs macOS 14+ and Xcode or the Command Line Tools (`xcode-select --install`).

---

## Gadgets

| Gadget | What it does | Instead of | Permissions |
|---|---|---|---|
| ☕ **Awake** | Keep your Mac awake for a while, until you say stop, or while an app runs. Optionally only on power, and with or without keeping the screen on. | Amphetamine, Lungo | none |
| 📋 **Clipboard** | Searchable history (⌃⌘V). **OTPs, API keys and passwords are wiped after 60 s**, from history and the clipboard, and never written to disk. Password-manager copies are never recorded. | Paste (~$30/yr), Maccy | Paste from Other Apps; Accessibility only for "paste directly" |
| 🎙 **Mic Mute** | One shortcut (⌃⌥M) mutes your mic in every app, with a red "Muted" sign on screen (click it to unmute). Stays muted when you switch to AirPods. | Mic Drop (~$5), MuteMe | none |
| 📥 **Drop Shelf** | Shake the cursor while dragging files and a shelf pops up. Park files there, drag them out later (one by one or all at once). Also ⌃⌥S. | Dropover (~$5), Yoink (~$9) | none |
| 🔊 Volume | Per-app volume and output routing. | SoundSource (~$47) | *coming* |
| 🔤 Text grab | Drag a box, copy the text in it (on-device OCR). | TextSniper (~$8) | *coming* |
| 🎬 Presentation mode | Hides desktop icons and notifications when you share your screen. | HiddenMe | *coming* |

A new gadget lands every week or two. Watch the repo to follow along.

## Install

### From source (recommended)

```bash
git clone https://github.com/Animesh0764/mac-belt.git
cd mac-belt
make install      # builds, copies Mac Belt to ~/Applications, opens it
```

Then look for the 🔧 icon in your menu bar. To start it at login: **Settings ▸ Open Mac Belt at login**.

| Command | Does |
|---|---|
| `make update` | `git pull` + reinstall |
| `make uninstall` | remove the app (keeps settings; `PURGE=1` removes them too) |
| `make test` | run the tests |
| `make run` | build and open without installing |

### Homebrew

Coming soon: `brew install Animesh0764/tap/mac-belt` (builds from source too).

### Why build from source?

Mac Belt is free, so it isn't signed with a paid Apple Developer ID. Apps you build yourself aren't blocked by Gatekeeper, and you can read every line before you run it.

#### About the "Mac Belt Local" certificate

macOS remembers permissions (Accessibility, Screen Recording…) by an app's code signature. A normal home-built app gets a new signature on every build, so macOS would ask again after every update.

`make install` therefore creates a self-signed certificate called **Mac Belt Local** (once, no sudo, no password prompt) and signs your build with it, so permissions survive updates. It's kept in its own small keychain in `~/Library/Application Support/MacBelt/signing/`, not your login keychain, and is only meaningful on your Mac. Skip it with `ADHOC=1 make install`, or remove it any time:

```bash
make remove-signing-identity
```

### Clipboard: one-time setup

macOS 15.4+ asks before an app reads the clipboard in the background. After the first prompt, set **System Settings ▸ Privacy & Security ▸ Paste from Other Apps ▸ Mac Belt ▸ Allow**, or macOS will ask on every copy.

## Privacy

- Everything runs on your Mac. Mac Belt makes **no network requests**.
- Clipboard history stays in `~/Library/Application Support/MacBelt/clipboard.sqlite` (readable only by you). Detected secrets live in memory only.
- No analytics, no crash reporting, no account.
- Settings are plain JSON in `~/Library/Application Support/MacBelt/`. Read them, edit them, delete them.
- Each gadget asks for a permission only when you switch it on, and the gallery shows which permissions each gadget needs.

## ☕ Support

Mac Belt is free and always will be. If it saved you from buying an app, consider buying me a coffee (or chai) instead:

- **Anywhere:** [GitHub Sponsors](https://github.com/sponsors/Animesh0764)
- **India (UPI):** scan the QR in the app (menu ▸ Support Mac Belt) or pay `singh.animesh.1@superyes`

Can't pay? Starring the repo, reporting a bug or telling a friend helps just as much.

## Contributing

Gadgets are small and self-contained, so each one is a good first PR. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to write one.

## More from the same author

- **OTTO**: clap-clap-snap-snap and your Mac opens your workspace and listens for voice commands.
- **Screenshot Memory**: search your screenshots by what's in them.

## License

MIT
