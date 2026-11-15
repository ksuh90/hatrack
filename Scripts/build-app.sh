#!/bin/bash
# Builds Hatrack.app: a menu-bar-only bundle, signed with a local identity,
# ready to open or drag to /Applications. No Xcode and no developer account
# needed.
#
# Launch the result with `open Hatrack.app` (`open -n` for a second copy), never
# by running Contents/MacOS/Hatrack from a shell: macOS files a menu bar item
# under the app that launched it first, so a shell launch puts Hatrack's icon
# under the terminal's "Allow in the Menu Bar" switch for good.
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
    <key>CFBundleIdentifier</key><string>com.hatrack.app</string>
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

# Every build is signed with the same self-signed certificate, so macOS sees
# each rebuild as the same app: one row in the menu bar settings, and the
# Keychain keeps trusting it with the API key. Ad-hoc signing would give every
# build a new identity.
IDENTITY_NAME="Hatrack Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_hash() {
    security find-identity -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null |
        awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }'
}

# One-time setup: a code-signing certificate valid for ten years, imported so
# that only codesign may use its key, which spares builds a password prompt.
# The system openssl (LibreSSL) writes a .p12 that `security import` accepts.
create_identity() {
    local dir
    dir="$(mktemp -d)"
    cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1 &&
    /usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
        -out "$dir/identity.p12" -passout pass:hatrack >/dev/null 2>&1 &&
    security import "$dir/identity.p12" -k "$LOGIN_KEYCHAIN" -P hatrack \
        -T /usr/bin/codesign >/dev/null
    local status=$?
    rm -rf "$dir"
    return $status
}

HASH="$(identity_hash)"
if [ -z "$HASH" ]; then
    echo "creating code-signing certificate \"$IDENTITY_NAME\" in the login keychain (one time)…"
    create_identity || true
    HASH="$(identity_hash)"
fi

if [ -n "$HASH" ] && codesign --force --sign "$HASH" --timestamp=none "$APP" 2>/dev/null; then
    echo "signed with \"$IDENTITY_NAME\""
else
    echo "warning: could not sign with \"$IDENTITY_NAME\"; signing ad hoc instead," \
         "so macOS will treat this build as a new app"
    codesign --force --sign - --timestamp=none "$APP" 2>/dev/null || \
        echo "note: ad-hoc signing failed; the app still runs locally"
fi

echo "built $APP"
