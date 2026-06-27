#!/usr/bin/env bash
# Build OCR Studio and package it into a drag-to-Applications DMG installer.
#
# Usage: scripts/make-dmg.sh
# Output: dist/OCR Studio.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OCR Studio"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"
VOL_NAME="$APP_NAME"

# 1. Build & sign the .app.
"$ROOT/scripts/make-app.sh" release

# 2. Stage the DMG contents: the app + an /Applications symlink.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Build a compressed DMG.
echo "==> Building DMG…"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "==> Done."
echo "    Installer: $DMG_PATH"
echo "    Open it, then drag '$APP_NAME' onto the Applications folder."
