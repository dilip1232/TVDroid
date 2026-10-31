#!/usr/bin/env bash
# Builds TVDroid.app in ./build.
#   --install  also copies the app to /Applications.
#   --dmg      also makes build/TVDroid-<version>.dmg.
# Optional environment:
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)". Default: ad-hoc signature.
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (app-specific password)
#                   With --dmg and a Developer ID: notarize and staple the DMG.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release
APP="build/TVDroid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/TVDroid" "$APP/Contents/MacOS/TVDroid"

swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>TVDroid uses the local network for the phone remote.</string>
  <key>NSBonjourServices</key><array><string>_http._tcp</string></array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Android app</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>apk</string><string>xapk</string><string>apks</string><string>apkm</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep -s - "$APP"
else
  # Hardened runtime and a secure timestamp are required for notarization.
  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION)"

for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/TVDroid.app
      cp -R "$APP" /Applications/
      echo "Installed /Applications/TVDroid.app"
      ;;
    --dmg)
      DMG="build/TVDroid-$VERSION.dmg"
      STAGE="build/dmg"
      rm -rf "$STAGE" "$DMG"
      mkdir -p "$STAGE"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      hdiutil create -volname "TVDroid $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
      rm -rf "$STAGE"
      if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
        if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
          echo "Notarizing $DMG (this takes a few minutes)…"
          xcrun notarytool submit "$DMG" --wait \
            --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
          xcrun stapler staple "$DMG"
        fi
      fi
      echo "Built $DMG"
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done
