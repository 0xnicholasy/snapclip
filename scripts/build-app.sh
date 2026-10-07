#!/bin/bash
# Builds build/SnapClip.app (release, ad-hoc signed). Works without Resources/AppIcon.icns.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/SnapClip.app"

swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SnapClip" "$APP/Contents/MacOS/SnapClip"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SnapClip</string>
    <key>CFBundleIdentifier</key><string>io.github.0xnicholasy.snapclip</string>
    <key>CFBundleName</key><string>SnapClip</string>
    <key>CFBundleDisplayName</key><string>SnapClip</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>SnapClip watches your screenshot folder to copy new screenshots to the clipboard.</string>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force -s - "$APP"
echo "Built $APP (version $VERSION)"
