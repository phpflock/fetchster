#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Fetchster"
BUNDLE_ID="com.shady.Fetchster"
VERSION="1.0.0"
BUILD_DIR="$PWD/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building with SwiftPM (release)..."
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "==> Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Engines (aria2, yt-dlp, ffmpeg) are not bundled: the app downloads them on
# demand from official sources (or the configured engine.*.url overrides),
# keeping the shipped app small.

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array><string>fetchster</string></array>
        </dict>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID.magnet</string>
            <key>CFBundleURLSchemes</key>
            <array><string>magnet</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Torrent File</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>torrent</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key><string>Fetchster</string>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)..."
find "$APP" -type f -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP"

echo ""
echo "Built: $APP"
echo "Run with: open \"$APP\""
