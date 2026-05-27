#!/usr/bin/env bash
# Build a simple unsigned .dmg containing the .app and an /Applications symlink.
# Usage: make_dmg.sh <path/to/App.app> <output.dmg>
set -euo pipefail

APP="${1:?path to .app required}"
OUT="${2:?output dmg path required}"
NAME="$(basename "$APP" .app)"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT"
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUT"

echo "Wrote $OUT"
