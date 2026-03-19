#!/bin/bash
set -euo pipefail

# Build release DMG for zMD with Applications symlink
# Usage: ./scripts/build-dmg.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_NAME="zMD.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
APP_NAME="zMD.app"

echo "==> Building Release..."
cd "$PROJECT_DIR"
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
    2>&1 | tail -5

if [ ! -d "$BUILD_DIR/Release/$APP_NAME" ]; then
    echo "ERROR: Build failed - no app found"
    exit 1
fi

echo "==> Preparing DMG staging..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app
cp -R "$BUILD_DIR/Release/$APP_NAME" "$STAGING_DIR/"

# Create Applications symlink
ln -sf /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG..."
rm -f "$DMG_PATH"

hdiutil create \
    -volname "zMD" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

echo "==> Done! DMG at: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
