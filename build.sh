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

# Sign with Developer ID for distribution outside App Store
SIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Sam Beran (3Z6WG8XPKY)}"
codesign --force --sign "$SIGN_IDENTITY" --entitlements Sources/FaceTouch.entitlements --options runtime "$APP_BUNDLE"

echo "Done! Run with: open $APP_BUNDLE"
