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
WORK="$(mktemp -d)"
BG="$WORK/background"
MOUNT="$WORK/mount"
TMPDMG="$WORK/staging.dmg"
DEVICE=""
OSA_PID=""
WATCHDOG_PID=""

cleanup() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$OSA_PID" ]; then
    kill "$OSA_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$DEVICE" ]; then
    hdiutil detach "$DEVICE" >/dev/null 2>&1 || true
  else
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$BG" "$MOUNT"

# 1. Build & sign the app.
"$ROOT/scripts/make-app.sh" release

# 2. Render the window background (1x + 2x → HiDPI tiff when possible).
( cd "$ROOT" && swift scripts/make-dmg-bg.swift "$BG" )
BGFILE="background.tiff"
if ! tiffutil -cathidpicheck "$BG/bg.png" "$BG/bg@2x.png" -out "$BG/background.tiff" 2>/dev/null; then
  cp "$BG/bg.png" "$BG/background.png"; BGFILE="background.png"
fi

# 3. Fresh read-write DMG; mount it at our private, unique mount point.
hdiutil create -volname "$VOL_NAME" -fs HFS+ -size 120m -ov "$TMPDMG" >/dev/null
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$TMPDMG")"
DEVICE="$(awk '/^\/dev\/disk[0-9]+[[:space:]]/ { print $1; exit }' <<<"$ATTACH")"
if [ -z "$DEVICE" ]; then
  echo "Could not determine the mounted DMG device." >&2
  exit 1
fi

# 4. Contents: the app, an /Applications symlink, and the hidden background.
cp -R "$APP_DIR" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
cp "$BG/$BGFILE" "$MOUNT/.background/$BGFILE"

# 5. Lay out the window (best-effort, bounded so Automation prompts cannot hang CI).
osascript <<EOF &
tell application "Finder"
  tell folder POSIX file "$MOUNT"
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
OSA_PID=$!
( sleep 20; kill "$OSA_PID" >/dev/null 2>&1 || true ) &
WATCHDOG_PID=$!
set +e
wait "$OSA_PID"
OSA_STATUS=$?
kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
OSA_PID=""
WATCHDOG_PID=""
set -e
if [ "$OSA_STATUS" -ne 0 ]; then
  echo "==> Note: could not style the window (grant Automation permission and re-run for the custom layout)."
fi

sync
if ! hdiutil detach "$DEVICE" >/dev/null; then
  echo "Could not detach temporary DMG device $DEVICE." >&2
  exit 1
fi
DEVICE=""

# 6. Compress to the final read-only DMG.
echo "==> Compressing DMG…"
rm -f "$DMG_PATH"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

echo "==> Done."
echo "    Installer: $DMG_PATH"
