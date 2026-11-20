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
BUNDLE_ID="io.github.macbelt.app"
IDENTITY_NAME="Mac Belt Local"

echo "→ swift build -c release"
swift build -c release --product MacBelt
BIN="$(swift build -c release --product MacBelt --show-bin-path)/MacBelt"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBelt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

SIGN_DIR="$HOME/Library/Application Support/MacBelt/signing"
SIGN_KEYCHAIN="$SIGN_DIR/macbelt-signing.keychain-db"
SIGN_PASSFILE="$SIGN_DIR/keychain-password"
HASH=""
if [[ "${MACBELT_ADHOC:-0}" != "1" && -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASSFILE" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_PASSFILE")" "$SIGN_KEYCHAIN" 2>/dev/null || true
  HASH="$(security find-certificate -c "$IDENTITY_NAME" -Z "$SIGN_KEYCHAIN" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}' || true)"
fi

if [[ -n "$HASH" ]]; then
  echo "→ codesign with \"$IDENTITY_NAME\" (stable: permissions survive updates)"
  codesign --force --keychain "$SIGN_KEYCHAIN" --sign "$HASH" --identifier "$BUNDLE_ID" "$APP"
else
  echo "→ codesign ad-hoc (permissions may be asked again after each rebuild;"
  echo "  run 'make signing-identity' once to avoid that)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "✓ built $(pwd)/$APP"
