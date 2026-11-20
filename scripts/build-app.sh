#!/bin/bash
# Builds build/MacBelt.app (release) and code-signs it.
#
# Signing:
#   - If the "Mac Belt Local" identity exists (make signing-identity), sign with it.
#     It lives in its own keychain (see signing-identity.sh), so there's no password prompt.
#     The signature then stays the same across rebuilds, so macOS remembers the
#     permissions you granted (Accessibility, Screen Recording, …) after updates.
#   - Otherwise sign ad-hoc. Works fine, but macOS may ask for permissions again
#     after each rebuild. Force this with MACBELT_ADHOC=1.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MacBelt.app"

# SWIFT_BUILD_FLAGS lets Homebrew add --disable-sandbox (its build already runs in a sandbox).
FLAGS=(${SWIFT_BUILD_FLAGS:-})
echo "→ swift build -c release"
swift build -c release --product MacBelt ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --product MacBelt --show-bin-path ${FLAGS[@]+"${FLAGS[@]}"})/MacBelt"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBelt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

scripts/sign-app.sh "$APP"

echo "✓ built $(pwd)/$APP"
