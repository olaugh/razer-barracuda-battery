#!/bin/bash
# Build RazerBatteryMenuBar, wrap it in a .app bundle, and install it.
#
#   PREFIX=~/Applications ./scripts/install.sh   (default)
#   PREFIX=/Applications  ./scripts/install.sh   (needs sudo)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="RazerBatteryMenuBar"
APP="$NAME.app"
DEST="${PREFIX:-$HOME/Applications}"

"$ROOT/scripts/build.sh"
BIN="$ROOT/.build/release/$NAME"
[ -x "$BIN" ] || { echo "error: build did not produce $BIN" >&2; exit 1; }

# Assemble the bundle.
BUILD_APP="$ROOT/.build/$APP"
rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
cp "$BIN" "$BUILD_APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"

# Ad-hoc signature: gives the app a stable identity, which SMAppService
# (launch-at-login) and TCC prompts key off of.
codesign --force --sign - "$BUILD_APP" >/dev/null 2>&1 || \
    echo "warning: codesign failed (app will still run, but login item may re-prompt)" >&2

# Install.
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$BUILD_APP" "$DEST/"

echo "Installed: $DEST/$APP"
echo "Launch:    open \"$DEST/$APP\""
echo "The 🎧 status will appear in the menu bar (no Dock icon)."
