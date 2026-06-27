#!/usr/bin/env bash
# Build OCR Studio and assemble a real .app bundle, then code-sign it.
#
# Usage: scripts/make-app.sh [debug|release]   (default: release)
#
# Signing: if a stable self-signed identity named "OCR Studio Local" exists in
# the keychain it is used (so the scanner's TCC permission grant survives
# rebuilds). Otherwise we fall back to ad-hoc signing, which always works for
# local runs but may re-prompt for scanner access after each rebuild. Run
# scripts/create-signing-cert.sh once to create the stable identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OCR Studio"
BUNDLE_ID="com.davidhucul.ocrstudio"
BIN_NAME="OCRStudio"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> Building OCR Studio ($CONFIG)…"
( cd "$ROOT" && swift build -c "$CONFIG" )

echo "==> Assembling app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "OCR Studio Local"; then
  IDENTITY="OCR Studio Local"
  echo "==> Signing with stable identity: $IDENTITY"
else
  echo "==> No stable cert found — using ad-hoc signing."
  echo "    (Scanner permission may re-prompt after rebuilds; run scripts/create-signing-cert.sh once to fix.)"
fi

# Hardened runtime first; if that combination is rejected, fall back to a plain sign.
if ! codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_DIR" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP_DIR"
fi

echo "==> Done."
echo "    App:  $APP_DIR"
echo "    Run:  open \"$APP_DIR\""
