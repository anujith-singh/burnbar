#!/bin/bash
# Build Burnbar, bundle it, install to ~/Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Burnbar
BIN="$(swift build -c release --show-bin-path)/Burnbar"

APP="build/Burnbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Burnbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

DEST="$HOME/Applications/Burnbar.app"
if pgrep -x Burnbar >/dev/null; then
    pkill -x Burnbar || true
    for _ in $(seq 50); do pgrep -x Burnbar >/dev/null || break; sleep 0.1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
# LaunchServices can refuse (-600) right after the old copy quits; retry once.
open "$DEST" || { sleep 1; open "$DEST"; }
echo "Installed and launched $DEST"
