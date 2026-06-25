#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Murmur"
BUNDLE_ID="ai.murmur.app"
TARGET="arm64-apple-macos26.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> compiling"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
swiftc \
    -swift-version 5 \
    -target "$TARGET" \
    -O \
    -o "$BUILD_DIR/$APP_NAME" \
    Sources/$APP_NAME/*.swift

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

if [ ! -f Resources/Murmur.icns ] && command -v rsvg-convert >/dev/null; then ./make-icon.sh; fi
if [ -f Resources/Murmur.icns ]; then cp Resources/Murmur.icns "$APP/Contents/Resources/Murmur.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>Murmur</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>26.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur transcribes your speech locally to type it for you.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Murmur transcribes your speech on-device.</string>
</dict>
</plist>
PLIST

SIGN_ID="Murmur Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> signing with stable identity ($SIGN_ID)"
    security unlock-keychain -p "murmur-local" murmur-signing.keychain 2>/dev/null || true
    codesign --force --sign "$SIGN_ID" "$APP"
else
    echo "==> ad-hoc signing (run ./setup-signing.sh once for permanent permissions)"
    codesign --force --deep --sign - "$APP"
fi

if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
echo "==> installing to $DEST/$APP_NAME.app"
rm -rf "$DEST/$APP_NAME.app"
ditto "$APP" "$DEST/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP_NAME.app" 2>/dev/null || true

# Keep only the installed copy — a second bundle with the same id confuses macOS privacy grants.
rm -rf "$BUILD_DIR"

echo "==> done: $DEST/$APP_NAME.app"
