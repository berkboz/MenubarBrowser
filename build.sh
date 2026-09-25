#!/bin/bash
# Builds build/Perch.app from the SwiftPM executable: a folder, a plist, the
# binary, the icons from Icon/, and an ad-hoc signature.
#
#   ./build.sh            release build, ad-hoc signed — runs on this Mac
#   ./build.sh debug      debug build
#   ./build.sh release zip  + build/Perch.zip to hand to someone
#
# Set PERCH_SIGN_IDENTITY to sign with a Developer ID instead.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
NAME="Perch"
APP="build/$NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/$NAME"

# The app icon: Icon/AppIcon.png (1024 px, already on Apple's icon grid),
# cut into every size an .icns wants. Without it, Icon/icon.swift draws one.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
if [ -f Icon/AppIcon.png ]; then
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Icon/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) Icon/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
  done
else
  swift Icon/icon.swift "$ICONSET" > /dev/null
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# The menu bar glyph, a template image at 1x, 2x and 3x.
cp Icon/MenuBarIcon*.png "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>app.perch.browser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <!-- No Dock icon, no menu bar of its own: Perch lives in the menu bar. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Perch — a browser that lives in your menu bar</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>public.xhtml</string><string>com.apple.web-internet-location</string></array>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

IDENTITY="${PERCH_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime --entitlements Perch.entitlements --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --deep --entitlements Perch.entitlements --sign - "$APP" 2>/dev/null || true
fi

echo "built: $APP ($VERSION, build $BUILD) — $(du -sh "$APP" | cut -f1)"
[ "$STEP" = "app" ] && exit 0

ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "packed: $ZIP"
