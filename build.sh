#!/bin/bash
set -e

APP_NAME="FaceTouch"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp Sources/Info.plist "$APP_BUNDLE/Contents/"
cp Sources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Sign: use Developer ID if available, otherwise ad-hoc
DEVID="Developer ID Application: Sam Beran (3Z6WG8XPKY)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVID"; then
    echo "Signing with Developer ID..."
    codesign --force --sign "$DEVID" --entitlements Sources/FaceTouch.entitlements --options runtime --deep "$APP_BUNDLE"
else
    echo "Developer ID not found, signing ad-hoc..."
    codesign --force --sign - --entitlements Sources/FaceTouch.entitlements "$APP_BUNDLE"
fi

echo "Done! Run with: open $APP_BUNDLE"
