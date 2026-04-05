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

# Sign with entitlements for camera access
codesign --force --sign - --entitlements Sources/FaceTouch.entitlements "$APP_BUNDLE"

echo "Done! Run with: open $APP_BUNDLE"
