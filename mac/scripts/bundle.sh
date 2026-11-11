#!/bin/sh
# Builds dist/TabletPen.app. Signs with the self-signed "TabletPen Dev" identity when it exists
# (stable across rebuilds, so macOS keeps the Accessibility grant); otherwise ad-hoc.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/TabletPen.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/TabletPenMac "$APP/Contents/MacOS/TabletPen"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.tabletpen.mac</string>
  <key>CFBundleName</key><string>TabletPen</string>
  <key>CFBundleExecutable</key><string>TabletPen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>TabletPen receives pen and touch input from your tablet over Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_tabletpen._tcp</string></array>
</dict></plist>
P
KC="$HOME/Library/Keychains/tabletpen-dev.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p tabletpen "$KC"
  ID="TabletPen Dev"
  codesign --force --sign "$ID" --keychain "$KC" --identifier dev.tabletpen.mac "$APP"
else
  ID="-"   # ad-hoc: works, but macOS forgets the Accessibility grant on every rebuild
  codesign --force --sign "$ID" --identifier dev.tabletpen.mac "$APP"
fi
echo "Built $APP (signed with: $ID)"
