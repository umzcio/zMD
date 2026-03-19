#!/bin/bash
set -euo pipefail

# Build release DMG for zMD with drag-to-Applications background
# Usage: ./scripts/build-dmg.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_NAME="zMD.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
VOLUME_NAME="zMD"
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
mkdir -p "$STAGING_DIR/.background"

# Copy app
cp -R "$BUILD_DIR/Release/$APP_NAME" "$STAGING_DIR/"

# Create Applications symlink
ln -sf /Applications "$STAGING_DIR/Applications"

# Generate background image with drag arrow
python3 - << 'PYEOF'
import struct, zlib, os

WIDTH, HEIGHT = 600, 400

def create_png(width, height, pixels):
    """Create a minimal PNG from RGBA pixel data."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))

    raw = b''
    for y in range(height):
        raw += b'\x00'  # filter none
        for x in range(width):
            raw += bytes(pixels[y][x])

    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

# Create pixels - dark background
pixels = [[(30, 30, 32, 255) for _ in range(WIDTH)] for _ in range(HEIGHT)]

# Draw arrow from left-center to right-center
# Arrow body: horizontal line
arrow_y = HEIGHT // 2
arrow_start_x = 180
arrow_end_x = 420
arrow_color = (180, 180, 185, 255)

for thickness in range(-3, 4):
    for x in range(arrow_start_x, arrow_end_x):
        y = arrow_y + thickness
        if 0 <= y < HEIGHT:
            pixels[y][x] = arrow_color

# Arrowhead
for i in range(25):
    for t in range(-i, i+1):
        y = arrow_y + t
        x = arrow_end_x + i - 25
        if 0 <= y < HEIGHT and 0 <= x < WIDTH:
            pixels[y][x] = arrow_color

# "Drag to install" text area (simple indicator below arrow)
text_y = arrow_y + 40
text_color = (120, 120, 125, 255)
# Draw a thin underline as visual hint
for x in range(220, 380):
    if 0 <= text_y < HEIGHT:
        pixels[text_y][x] = text_color

build_dir = os.environ.get('BUILD_DIR', 'build')
path = os.path.join(build_dir, 'dmg-staging', '.background', 'background.png')
with open(path, 'wb') as f:
    f.write(create_png(WIDTH, HEIGHT, pixels))
print(f"Background image written to {path}")
PYEOF

echo "==> Creating DMG..."
rm -f "$DMG_PATH"

# Create temporary DMG (read-write)
TEMP_DMG="$BUILD_DIR/zMD-temp.dmg"
hdiutil create -size 100m -fs HFS+ -volname "$VOLUME_NAME" -o "$TEMP_DMG" -quiet

# Mount it
MOUNT_DIR=$(hdiutil attach "$TEMP_DMG" -readwrite -nobrowse -plist | \
    python3 -c "import sys,plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print([e['mount-point'] for e in d['system-entities'] if 'mount-point' in e][0])")

# Copy contents
cp -R "$STAGING_DIR/"* "$MOUNT_DIR/"
cp -R "$STAGING_DIR/.background" "$MOUNT_DIR/"

# Set DMG window properties via AppleScript
osascript << ASEOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 700, 500}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
ASEOF

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet
rm -f "$TEMP_DMG"

echo "==> Done! DMG at: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
