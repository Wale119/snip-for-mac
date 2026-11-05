#!/bin/bash
# Retakes the README screenshots of Snip's own windows: about.png, editor.png and notification.png.
# (snipping.png is a mock-up of a dimmed screen and isn't regenerated here.)
# Run from anywhere: ./tools/screenshots.sh   (takes about 20 seconds)
# Needs Screen Recording permission for your terminal. Briefly quits a running Snip and restarts it afterwards.
#
# PRIVACY: these images are public. They only show Snip's own windows, never your screen, and every
# image is re-saved without metadata or the display's color profile (which can name your monitor).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/screenshots
APP=build/Snip.app/Contents/MacOS/Snip
EXPECTED=(about editor notification)
mkdir -p "$OUT"
for n in "${EXPECTED[@]}"; do rm -f "$OUT/$n.png"; done  # a failed shot must never leave an old image behind

./build.sh >/dev/null
swiftc -O tools/window_info.swift -o build/window_info

# Keep the display awake while this runs; if it dims or sleeps, the captures come out black.
caffeinate -d -w $$ &

was_running=0
pgrep -x Snip >/dev/null && was_running=1
pkill -x Snip || true
sleep 1

# Always stop the test copy and bring back the user's Snip, even if a step fails.
cleanup() {
    pkill -f "$APP" 2>/dev/null || true
    if [ "$was_running" = 1 ]; then open /Applications/Snip.app; fi
}
trap cleanup EXIT

# capture <output.png> <seconds to wait> <app arguments...>
# Launches a fresh copy of Snip and saves its largest window, with its shadow unless NO_SHADOW=1.
capture() {
    local out=$1 wait=$2
    shift 2
    "$APP" "$@" >/dev/null 2>&1 &
    local pid=$!
    sleep "$wait"
    local id opts=(-x)
    [ "${NO_SHADOW:-0}" = 1 ] && opts+=(-o)
    id=$(build/window_info "$pid" | awk '{ a = $4 * $5; if (a > best) { best = a; id = $1 } } END { print id }')
    if [ -n "$id" ]; then screencapture "${opts[@]}" -l "$id" "$out"; fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

echo "About window..."
capture "$OUT/about.png" 3 --about
# The editor and notification shots show a window snip of the About window (no shadow, like a real
# window snip). The DPI tells Snip the image's scale: 72 = standard display, 144 = Retina.
rm -f build/about-snip.png
NO_SHADOW=1 capture build/about-snip.png 3 --about
[ -f build/about-snip.png ] || { echo "Could not capture the About window."; exit 1; }
DPI=$(( $(build/window_info --main-scale) * 72 ))
sips -s dpiWidth "$DPI" -s dpiHeight "$DPI" build/about-snip.png >/dev/null

echo "Editor with example pen and highlighter marks..."
capture "$OUT/editor.png" 4 --open build/about-snip.png --demo-markup

echo "Notification..."
capture "$OUT/notification.png" 2 --toast build/about-snip.png

FILES=()
for n in "${EXPECTED[@]}"; do FILES+=("$OUT/$n.png"); done
if ! build/window_info --check "${FILES[@]}"; then
    echo "Some screenshots are missing or blank. Keep the screen awake and unlocked, close full-screen apps, and run again."
    exit 1
fi
build/window_info --strip "${FILES[@]}"   # remove image metadata and the display's color profile
echo "Saved:" && ls -1 "$OUT"
echo "Check every image for personal information before committing."
