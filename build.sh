#!/bin/bash
# Builds Snip.app into ./build. Usage: ./build.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Snip.app
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/Snip"

cp Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    echo "Making icon…"
    swift tools/make_icon.swift build/icon_1024.png
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a real certificate if one exists, so macOS's Screen Recording permission
# survives rebuilds. (Ad-hoc "-" signing gives every build a new identity.)
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application|Snip Local Signing)[^"]*"' | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Warning: ad-hoc signed; Screen Recording permission will reset on every rebuild."
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Snip 2>/dev/null || true
    rm -rf /Applications/Snip.app
    cp -R "$APP" /Applications/Snip.app
    echo "Installed to /Applications/Snip.app"
    open /Applications/Snip.app
fi
