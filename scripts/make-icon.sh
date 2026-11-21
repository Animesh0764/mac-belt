#!/bin/bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
# Only needed when the icon design changes; the .icns is committed.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
swift scripts/make-icon.swift "$TMP/1024.png" 1024
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/1024.png" docs/icon.png 2>/dev/null || true
echo "✓ Resources/AppIcon.icns"
