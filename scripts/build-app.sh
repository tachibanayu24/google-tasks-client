#!/bin/zsh
# Builds "Dueday.app" into ./build.
#   --install  copy it to /Applications and launch it
#   --dev      build "Dueday Dev.app" with its own bundle id (separate settings & account) for testing
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Dueday"
BUNDLE_ID="com.tachibanayu24.Dueday"
INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --dev) APP_NAME="Dueday Dev"; BUNDLE_ID="com.tachibanayu24.Dueday.dev" ;;
        --install) INSTALL=true ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done
VERSION="0.1.0"
APP="build/${APP_NAME}.app"
EXE="$APP/Contents/MacOS/Dueday"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

# SwiftPM resource bundles can't live inside a signed .app where SwiftPM's generated code looks for them,
# so no dependency may declare resources (see Vendor/). Fail loudly if one sneaks in.
bundles=("$BIN_DIR"/*.bundle(N))
if (( ${#bundles} )); then
    echo "error: unexpected SwiftPM resource bundles: ${bundles[*]}" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Dueday" "$EXE"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Dueday</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (the app embeds no frameworks).
codesign --force --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"
echo "Built $APP"

if $INSTALL; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in {1..50}; do
        pgrep -f "/Applications/${APP_NAME}.app/Contents/MacOS/" >/dev/null || break
        sleep 0.1
    done
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "Installed to /Applications"
fi
