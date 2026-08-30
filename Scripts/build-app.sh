#!/bin/bash
# Builds Hatrack.app: a menu-bar-only bundle, ad-hoc signed, ready to run
# or drag to /Applications. No Xcode and no developer account needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/Hatrack.app"

echo "building ($CONFIG)…"
swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/Hatrack"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hatrack"

# The icon is drawn by the app itself, from the same aircraft path the menu bar
# uses, then packed into an .icns.
ICONSET="$(mktemp -d)/Hatrack.iconset"
"$BIN" --render-iconset "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Hatrack</string>
    <key>CFBundleDisplayName</key><string>Hatrack</string>
    <key>CFBundleIdentifier</key><string>com.hatrack.menubar</string>
    <key>CFBundleExecutable</key><string>Hatrack</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- menu bar only: no Dock icon, no app switcher entry -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
    echo "note: ad-hoc signing failed; the app still runs locally"

echo "built $APP"
