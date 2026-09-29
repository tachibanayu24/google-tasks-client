#!/bin/zsh
# Regenerates the README images in docs/ from the dev build with sample data (no Google account needed).
# Takes over the screen for about half a minute: the panel and a drawn wallpaper appear mid-screen.
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="build/Google Tasks Client Dev.app"
DOMAIN="com.tachibanayu24.GoogleTasksClient.dev"
TMP="$(mktemp -d)"
./scripts/build-app.sh --dev >/dev/null
swiftc -O scripts/docs/shoot.swift -o "$TMP/shoot"
cat > "$TMP/notify.swift" <<'SWIFT'
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("GoogleTasksClientDev." + CommandLine.arguments[1]), object: nil, userInfo: nil, deliverImmediately: true)
SWIFT
swiftc "$TMP/notify.swift" -o "$TMP/notify"
dev() { "$TMP/notify" "$1"; sleep "${2:-0.6}"; }

# shot <file> <theme> <menu bar state> <tabs to advance> [finish]
shot() {
    pkill -f "$APP/Contents/MacOS/" || true
    sleep 0.5
    defaults write "$DOMAIN" theme "$2"
    defaults write "$DOMAIN" showingToday -bool true
    open "$APP"
    sleep 2
    dev demo 0.3
    dev preview 1.2
    repeat "$4" dev next 0.4
    dev zoom 1.2
    "$TMP/shoot" "$TMP/shot.png" "$2" "$3" &
    # Finish just before the picture is taken (1.2 s after the backdrop appears), with the confetti mid-air.
    if [[ "${5:-}" == finish ]]; then sleep 0.5; dev finish 0; fi
    wait
    # Photos of gradients and glass: JPEG keeps them a tenth of the size.
    sips -s format jpeg -s formatOptions 88 "$TMP/shot.png" --out "docs/$1" >/dev/null
}

"$TMP/shoot" --states docs/menubar.png
shot hero-dark.jpg dark ring:4:0.2 0
shot hero-light.jpg light ring:4:0.2 0
shot list.jpg light ring:4:0.2 1
shot all-done.jpg dark party 0 finish

pkill -f "$APP/Contents/MacOS/" || true
defaults delete "$DOMAIN" theme
rm -rf "$TMP"
echo "Updated docs/"
