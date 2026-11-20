#!/bin/bash
# Creates a self-signed code-signing certificate called "Mac Belt Local", once.
# build-app.sh signs with it so the app's signature is the same after every rebuild,
# and macOS keeps the permissions you granted (Accessibility, Screen Recording, …).
#
# It lives in its own small keychain, not your login keychain, so builds never ask
# for your password:
#   ~/Library/Application Support/MacBelt/signing/macbelt-signing.keychain-db
# The keychain's random password sits next to it in a file only you can read.
#
# It isn't trusted system-wide, needs no sudo, and is meaningful only on this Mac.
# Remove it any time:  make remove-signing-identity
set -euo pipefail

NAME="Mac Belt Local"
DIR="$HOME/Library/Application Support/MacBelt/signing"
KEYCHAIN="$DIR/macbelt-signing.keychain-db"
PASSFILE="$DIR/keychain-password"

if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]] &&
   security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ \"$NAME\" signing identity already exists"
  exit 0
fi

echo "→ creating the \"$NAME\" signing identity (one time, no password needed)"
mkdir -p "$DIR"
chmod 700 "$DIR"
rm -f "$KEYCHAIN" "$PASSFILE"

KC_PASS="$(/usr/bin/openssl rand -hex 24)"
(umask 077; printf '%s' "$KC_PASS" > "$PASSFILE")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# macOS's own LibreSSL: its PKCS#12 output is what `security import` expects.
OPENSSL=/usr/bin/openssl
P12_PASS="$(/usr/bin/openssl rand -hex 16)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/$NAME.p12" -passout "pass:$P12_PASS"

security create-keychain -p "$KC_PASS" "$KEYCHAIN" >/dev/null
chmod 600 "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$TMP/$NAME.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without any dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
echo "✓ created. Builds are now signed with \"$NAME\"."
