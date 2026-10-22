#!/usr/bin/env bash
# Builds TVDroid.app in ./build. Add --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/TVDroid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TVDroid" "$APP/Contents/MacOS/TVDroid"

swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TVDroid</string>
  <key>CFBundleDisplayName</key><string>TVDroid</string>
  <key>CFBundleIdentifier</key><string>local.tvdroid</string>
  <key>CFBundleExecutable</key><string>TVDroid</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>TVDroid uses the local network for the phone remote.</string>
  <key>NSBonjourServices</key><array><string>_http._tcp</string></array>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/TVDroid.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/TVDroid.app"
fi
