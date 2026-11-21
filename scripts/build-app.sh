#!/bin/bash
# Builds BKSwitcher.app (menu bar app + CLI) into build/, optionally installing it.
#
# Usage:
#   scripts/build-app.sh                  Build build/BKSwitcher.app
#   scripts/build-app.sh --install        Build, then copy to /Applications (quits a running copy first)
#   scripts/build-app.sh --regenerate-icon  Redraw Packaging/AppIcon.icns from scripts/make-icon.swift first
set -euo pipefail

cd "$(dirname "$0")/.."

INSTALL=false
REGENERATE_ICON=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --regenerate-icon) REGENERATE_ICON=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

ICNS="Packaging/AppIcon.icns"
if $REGENERATE_ICON || [ ! -f "$ICNS" ]; then
    echo "==> Drawing app icon"
    WORK="build/icon"
    rm -rf "$WORK" && mkdir -p "$WORK/AppIcon.iconset"
    swift scripts/make-icon.swift "$WORK/AppIcon-1024.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$WORK/AppIcon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$WORK/AppIcon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$WORK/AppIcon.iconset" -o "$ICNS"
fi

echo "==> Building release binary"
swift build -c release

APP="build/BKSwitcher.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/bkswitcher "$APP/Contents/MacOS/bkswitcher"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS can attach Photos/Automation permissions to the app's identity.
codesign --force --sign - "$APP"

if $INSTALL; then
    DEST="/Applications/BKSwitcher.app"
    if pgrep -f "$DEST/Contents/MacOS/bkswitcher" >/dev/null; then
        echo "==> Quitting running BKSwitcher"
        pkill -f "$DEST/Contents/MacOS/bkswitcher" || true
        sleep 1
    fi
    echo "==> Installing to $DEST"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed. Launch it with: open \"$DEST\""
else
    echo "Built $APP. Run it with: open \"$APP\""
fi
