#!/usr/bin/env bash
# Build a macOS Installer package that installs OCR Studio into /Applications.
# Output: dist/OCR Studio.pkg. Use --skip-build only after make-app.sh/make-dmg.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="OCR Studio"
APP_DIR="$ROOT/dist/$APP_NAME.app"
PKG_PATH="$ROOT/dist/$APP_NAME.pkg"

case "${1:-}" in
  "") "$ROOT/scripts/make-app.sh" release ;;
  --skip-build) ;;
  *) echo "usage: $0 [--skip-build]" >&2; exit 64 ;;
esac

codesign --verify --deep --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")"
WORK="$(mktemp -d "$ROOT/dist/.pkg-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/root"
mkdir -p "$STAGE/Applications"
ditto "$APP_DIR" "$STAGE/Applications/$APP_NAME.app"

pkgbuild --analyze --root "$STAGE" "$WORK/components.plist"
# Never relocate installation to an older copy in Downloads or another folder.
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$WORK/components.plist"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$WORK/components.plist"
pkgbuild --root "$STAGE" --component-plist "$WORK/components.plist" \
  --identifier com.davidhucul.ocrstudio.installer --version "$VERSION" \
  --install-location / --ownership recommended "$WORK/OCRStudio-component.pkg"

productbuild --synthesize --package "$WORK/OCRStudio-component.pkg" "$WORK/distribution.xml"
python3 - "$WORK/distribution.xml" "$APP_DIR/Contents/MacOS/OCRStudio" "$MIN_OS" <<'PY'
import subprocess
import sys
import xml.etree.ElementTree as ET

path, executable, minimum_os = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
title = root.find('title')
if title is None:
    title = ET.SubElement(root, 'title')
title.text = 'OCR Studio'
for existing in root.findall('domains'):
    root.remove(existing)
ET.SubElement(root, 'domains', enable_anywhere='false',
              enable_currentUserHome='false', enable_localSystem='true')
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('customize', 'never')
options.set('require-scripts', 'false')
options.set('hostArchitectures', ','.join(subprocess.check_output(
    ['lipo', '-archs', executable], text=True).split()))
volume = root.find('volume-check')
if volume is None:
    volume = ET.SubElement(root, 'volume-check')
allowed = ET.SubElement(volume, 'allowed-os-versions')
ET.SubElement(allowed, 'os-version', min=minimum_os)
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" \
  "$WORK/$APP_NAME.pkg"
# Publish only after the complete package has been built successfully.
mv -f "$WORK/$APP_NAME.pkg" "$PKG_PATH"
echo "==> Installer: $PKG_PATH"
echo "    Version: $VERSION"
echo "    Installs: /Applications/$APP_NAME.app"
