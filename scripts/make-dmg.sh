#!/usr/bin/env bash
# Build OCR Studio and package it into a styled drag-to-Applications DMG:
# a custom background with a title, an arrow, the app icon, and the Applications
# folder. Output: dist/OCR Studio.dmg
#
# Note: the window styling step controls Finder via AppleScript, which needs
# Automation permission the first time (macOS will prompt). If that's denied the
# DMG is still produced, just without the custom layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OCR Studio"
VOL_NAME="OCR Studio"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME.dmg"

# 1. Build & sign the app.
"$ROOT/scripts/make-app.sh" release

# 2. Render the window background (1x + 2x → HiDPI tiff when possible).
BG="$(mktemp -d)"
trap 'rm -rf "$BG"' EXIT
( cd "$ROOT" && swift scripts/make-dmg-bg.swift "$BG" )
BGFILE="background.tiff"
if ! tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$BG/background.tiff" 2>/dev/null; then
  cp "$BG/bg.png" "$BG/background.png"; BGFILE="background.png"
fi

# 3. Fresh read-write DMG; mount it.
hdiutil detach "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true
TMPDMG="$(mktemp -u).dmg"
hdiutil create -volname "$VOL_NAME" -fs HFS+ -size 120m -ov "$TMPDMG" >/dev/null
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG")"
DEVICE="$(echo "$ATTACH" | grep -Eo '^/dev/disk[0-9]+' | head -1)"
MOUNT="$(echo "$ATTACH" | grep -Eo '/Volumes/.*$' | head -1)"

# 4. Contents: the app, an /Applications symlink, and the hidden background.
cp -R "$APP_DIR" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
cp "$BG/$BGFILE" "$MOUNT/.background/$BGFILE"

# 5. Lay out the window (best-effort).
if ! osascript <<EOF
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set background picture of theViewOptions to file ".background:$BGFILE"
    set position of item "$APP_NAME.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    close
    open
    delay 1
  end tell
end tell
EOF
then
  echo "==> Note: could not style the window (grant Automation permission and re-run for the custom layout)."
fi

sync
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$MOUNT" >/dev/null 2>&1 || true

# 6. Compress to the final read-only DMG.
echo "==> Compressing DMG…"
rm -f "$DMG_PATH"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMPDMG"

echo "==> Done."
echo "    Installer: $DMG_PATH"
