#!/bin/bash
set -euo pipefail

# Build release DMG for zMD with Chrome-style drag-to-Applications layout
# Usage: ./scripts/build-dmg.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DMG_NAME="zMD.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
TEMP_DMG="$BUILD_DIR/zMD-temp.dmg"
APP_NAME="zMD.app"
VOLUME_NAME="zMD"

# Window dimensions
WIN_W=480
WIN_H=540
WIN_X=200
WIN_Y=200

echo "==> Building Release..."
cd "$PROJECT_DIR"
# Notarization-required signing flags:
#   --timestamp                          → embed Apple secure-timestamp (notary requires it)
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO → don't inject the Debug-only `get-task-allow` entitlement
# Without these, notarytool returns "Invalid: signature does not include a secure timestamp" and
# "executable requests the com.apple.security.get-task-allow entitlement".
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/Release" \
    OTHER_CODE_SIGN_FLAGS='--timestamp' \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    2>&1 | tail -5

if [ ! -d "$BUILD_DIR/Release/$APP_NAME" ]; then
    echo "ERROR: Build failed - no app found"
    exit 1
fi

echo "==> Generating background image..."
python3 - "$BUILD_DIR" "$WIN_W" "$WIN_H" << 'PYEOF'
import struct, zlib, sys, os, math

build_dir = sys.argv[1]
W = int(sys.argv[2])   # 1x — must match window size exactly
H = int(sys.argv[3])

def create_png(width, height, pixels):
    def chunk(ct, data):
        c = ct + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            raw += bytes(pixels[y * width + x])
    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

def blend(bg, fg):
    """Alpha-blend fg onto bg."""
    a = fg[3] / 255.0
    return (
        int(bg[0] * (1 - a) + fg[0] * a),
        int(bg[1] * (1 - a) + fg[1] * a),
        int(bg[2] * (1 - a) + fg[2] * a),
        255
    )

# White background
pixels = [(255, 255, 255, 255)] * (W * H)

# Clean arrow between app icon (y=140) and Applications (y=400)
cx = W // 2
ac = (175, 180, 188, 255)

# Use distance-field approach for smooth anti-aliased arrow
def arrow_sdf(px, py):
    """Signed distance to arrow shape. Negative = inside."""
    # Shaft: rectangle from y=218 to y=295, half-width 5
    shaft_top, shaft_bot, shaft_hw = 218, 295, 5
    # Head: triangle from y=280 to y=340, half-width 30 at top tapering to 0
    head_top, head_bot, head_hw = 280, 338, 30

    dx = px - cx
    dy = py

    # Head triangle
    if dy >= head_top and dy <= head_bot:
        progress = (dy - head_top) / (head_bot - head_top)
        hw = head_hw * (1.0 - progress)
        dist_x = abs(dx) - hw
        if dy <= head_bot:
            # Inside or near triangle
            dist_y_top = head_top - dy
            dist_y_bot = dy - head_bot
            if dist_x <= 0:
                return max(dist_x, dist_y_top, dist_y_bot)
            else:
                return dist_x

    # Shaft rectangle
    if dy >= shaft_top and dy <= shaft_bot:
        dist_x = abs(dx) - shaft_hw
        dist_y = max(shaft_top - dy, dy - shaft_bot)
        if dist_x <= 0 and dist_y <= 0:
            return max(dist_x, dist_y)
        elif dist_x > 0 and dist_y > 0:
            return math.sqrt(dist_x**2 + dist_y**2)
        else:
            return max(dist_x, dist_y)

    # Outside both shapes - find nearest
    dists = []
    # Distance to shaft
    clamped_y = max(shaft_top, min(shaft_bot, dy))
    dist_to_shaft_x = abs(dx) - shaft_hw
    dist_to_shaft_y = abs(dy - clamped_y)
    if dist_to_shaft_x <= 0:
        dists.append(dist_to_shaft_y)
    else:
        dists.append(math.sqrt(dist_to_shaft_x**2 + dist_to_shaft_y**2))

    # Distance to head
    if dy >= head_top:
        clamped_hy = max(head_top, min(head_bot, dy))
        progress = (clamped_hy - head_top) / (head_bot - head_top)
        hw = head_hw * (1.0 - progress)
        dist_hx = abs(dx) - hw
        if dist_hx <= 0:
            dists.append(abs(dy - clamped_hy))
        else:
            dists.append(math.sqrt(dist_hx**2 + (dy - clamped_hy)**2))
    else:
        dists.append(abs(dy - head_top) + max(0, abs(dx) - head_hw))

    return min(dists) if dists else 999

for y in range(200, 355):
    for x in range(cx - 45, cx + 45):
        if 0 <= x < W and 0 <= y < H:
            d = arrow_sdf(x, y)
            if d < -1.0:
                pixels[y * W + x] = ac
            elif d < 1.0:
                # Anti-alias edge
                t = 0.5 - d * 0.5
                t = max(0.0, min(1.0, t))
                bg = pixels[y * W + x]
                pixels[y * W + x] = (
                    int(bg[0] * (1-t) + ac[0] * t),
                    int(bg[1] * (1-t) + ac[1] * t),
                    int(bg[2] * (1-t) + ac[2] * t),
                    255
                )

out_dir = os.path.join(build_dir, 'dmg-background')
os.makedirs(out_dir, exist_ok=True)
path = os.path.join(out_dir, 'background.png')
with open(path, 'wb') as f:
    f.write(create_png(W, H, pixels))
print(f"Background image: {path} ({W}x{H})")
PYEOF

echo "==> Creating DMG..."
rm -f "$DMG_PATH" "$TEMP_DMG"

# Create writable DMG
hdiutil create -size 50m -fs HFS+ -volname "$VOLUME_NAME" "$TEMP_DMG" -quiet

# Mount writable
MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen -plist)
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | python3 -c "
import sys, plistlib
d = plistlib.loads(sys.stdin.buffer.read())
for e in d.get('system-entities', []):
    if 'mount-point' in e:
        print(e['mount-point'])
        break
")

echo "    Mounted at: $MOUNT_DIR"

# Copy app and create Applications symlink
cp -R "$BUILD_DIR/Release/$APP_NAME" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Copy background
mkdir "$MOUNT_DIR/.background"
cp "$BUILD_DIR/dmg-background/background.png" "$MOUNT_DIR/.background/background.png"

# Use AppleScript to configure the DMG window
echo "==> Configuring DMG layout..."
sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {${WIN_X}, ${WIN_Y}, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set background picture of theViewOptions to file ".background:background.png"

        -- App on top center, Applications on bottom center
        set position of item "${APP_NAME}" of container window to {$((WIN_W / 2)), 140}
        set position of item "Applications" of container window to {$((WIN_W / 2)), 400}

        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Make sure writes are flushed
sync

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet
rm -f "$TEMP_DMG"

# Notarize + staple. Apple's API key is in ~/Downloads/AuthKey_GDJWLVZ2PS.p8 (key ID
# GDJWLVZ2PS, issuer 69a6de75-9781-47e3-e053-5b8c7c11a4d1, team 5JJ6G6A84S). The DMG built
# above contains an unsignedticket .app — we submit, wait for Accepted, then RE-PACKAGE so the
# .app inside the final DMG carries its own staple (offline-launch trust). Without the
# re-package, only the DMG container is stapled and `stapler validate` on the .app fails.
# Set NOTARIZE=0 in the environment to skip (e.g., for fast local iteration).
NOTARY_KEY="$HOME/Downloads/AuthKey_GDJWLVZ2PS.p8"
NOTARY_KEY_ID="GDJWLVZ2PS"
NOTARY_ISSUER="69a6de75-9781-47e3-e053-5b8c7c11a4d1"

if [ "${NOTARIZE:-1}" != "0" ]; then
    if [ ! -f "$NOTARY_KEY" ]; then
        echo "==> WARN: notary API key not found at $NOTARY_KEY — skipping notarization."
        echo "    See memory/project_notarization.md for setup. Re-run after restoring the key."
    else
        echo "==> Submitting DMG to Apple notary service (this can take a few minutes)..."
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
            --wait 2>&1 | tee /tmp/zmd-notary.log
        STATUS=$(grep -E "^\s*status:" /tmp/zmd-notary.log | tail -1 | awk '{print $2}')
        if [ "$STATUS" != "Accepted" ]; then
            echo "==> ERROR: notarization status was '$STATUS', expected 'Accepted'."
            echo "    Fetch full log:"
            SUBMIT_ID=$(grep -E "^\s*id:" /tmp/zmd-notary.log | head -1 | awk '{print $2}')
            echo "    xcrun notarytool log $SUBMIT_ID --key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER"
            exit 1
        fi

        echo "==> Stapling .app and re-packaging DMG (so the .app inside is also stapled)..."
        xcrun stapler staple "$BUILD_DIR/Release/$APP_NAME" 2>&1 | tail -1

        # Re-create DMG with the now-stapled .app so users get offline-launch-ready bundles.
        rm -f "$DMG_PATH" "$TEMP_DMG"
        hdiutil create -size 50m -fs HFS+ -volname "$VOLUME_NAME" "$TEMP_DMG" -quiet
        MOUNT_OUTPUT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen -plist)
        MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | python3 -c "import sys, plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print([e['mount-point'] for e in d.get('system-entities',[]) if 'mount-point' in e][0])")
        cp -R "$BUILD_DIR/Release/$APP_NAME" "$MOUNT_DIR/"
        ln -s /Applications "$MOUNT_DIR/Applications"
        mkdir "$MOUNT_DIR/.background"
        cp "$BUILD_DIR/dmg-background/background.png" "$MOUNT_DIR/.background/background.png"
        osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {${WIN_X}, ${WIN_Y}, $((WIN_X + WIN_W)), $((WIN_Y + WIN_H))}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}" of container window to {$((WIN_W / 2)), 140}
        set position of item "Applications" of container window to {$((WIN_W / 2)), 400}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
        sync
        hdiutil detach "$MOUNT_DIR" -quiet
        hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet
        rm -f "$TEMP_DMG"

        echo "==> Re-submitting repackaged DMG (hash changed) and stapling..."
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
            --wait 2>&1 | tee /tmp/zmd-notary.log
        STATUS=$(grep -E "^\s*status:" /tmp/zmd-notary.log | tail -1 | awk '{print $2}')
        if [ "$STATUS" != "Accepted" ]; then
            echo "==> ERROR: re-notarization status was '$STATUS', expected 'Accepted'."
            exit 1
        fi
        xcrun stapler staple "$DMG_PATH" 2>&1 | tail -1

        echo "==> Verifying:"
        TMP_MOUNT=$(hdiutil attach "$DMG_PATH" -nobrowse -plist | python3 -c "import sys, plistlib; d=plistlib.loads(sys.stdin.buffer.read()); print([e['mount-point'] for e in d.get('system-entities',[]) if 'mount-point' in e][0])")
        spctl -a -vv "$TMP_MOUNT/$APP_NAME" 2>&1 | tail -3
        hdiutil detach "$TMP_MOUNT" -quiet
    fi
fi

echo "==> Done! DMG at: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
