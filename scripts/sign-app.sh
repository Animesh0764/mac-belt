#!/bin/bash
# Code-signs a built MacBelt.app.
#   - With the "Mac Belt Local" identity if it exists (scripts/signing-identity.sh):
#     the signature stays the same across updates, so macOS keeps your permissions.
#   - Otherwise ad-hoc (or always, with MACBELT_ADHOC=1). macOS may then ask for
#     permissions again after each update.
# Usage: sign-app.sh path/to/MacBelt.app
set -euo pipefail
APP="${1:?usage: sign-app.sh MacBelt.app}"
BUNDLE_ID="io.github.macbelt.app"
IDENTITY_NAME="Mac Belt Local"

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
  echo "→ codesign ad-hoc (permissions may be asked again after each update)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"
