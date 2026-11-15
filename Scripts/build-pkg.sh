#!/bin/bash
# Wraps a built Hatrack.app (see build-app.sh) in Hatrack.pkg, an installer
# that puts the app in /Applications.
#
# The package has no install scripts, so it never launches the app: the user
# opens it from Spotlight or Finder. An installer script runs as root from
# Installer, and a launch from there could file the menu bar item under the
# wrong app (see build-app.sh) or start the app as the wrong user.
#
# Usage: build-pkg.sh [output.pkg]   (default: Hatrack.pkg in the repo root)
# HATRACK_VERSION sets the package version (default 1.0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Hatrack.app"
OUT="${1:-$ROOT/Hatrack.pkg}"
VERSION="${HATRACK_VERSION:-1.0}"

[ -d "$APP" ] || { echo "error: $APP not found; run Scripts/build-app.sh first" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root"
# A quarantine flag or other extended attribute on the build would be installed
# with it; the signature does not need them.
ditto --noextattr --noqtn --noacl "$APP" "$WORK/root/Hatrack.app"

# By default Installer "relocates" a bundle: if another copy with the same
# bundle id exists anywhere (a build in a source checkout, say), it updates that
# copy instead of installing to /Applications. Turn that off.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"

pkgbuild --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --install-location /Applications \
    --identifier com.hatrack.app.pkg \
    --version "$VERSION" \
    "$OUT"
