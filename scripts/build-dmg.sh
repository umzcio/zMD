#!/bin/bash
set -euo pipefail

# Build the notarized release DMG for zMD: a branded drag-to-Applications window
# (create-dmg + a background rendered by scripts/render-dmg-background.swift, the
# same pattern as zStats and zWhisper).
# Usage: ./scripts/build-dmg.sh          (NOTARIZE=0 to skip the notary loop)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DMG_NAME="zMD.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
APP_NAME="zMD.app"
VOLUME_NAME="Install zMD"
ARTWORK="$BUILD_DIR/dmg-artwork"

command -v create-dmg > /dev/null || { echo "Install create-dmg first: brew install create-dmg" >&2; exit 1; }

NOTARY_LOG="$(mktemp -t zmd-notary)"
trap 'rm -f "$NOTARY_LOG"' EXIT

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

echo "==> Rendering background..."
mkdir -p "$ARTWORK"
swift "$SCRIPT_DIR/render-dmg-background.swift" "$ARTWORK/background.png"

# Package build/Release/zMD.app into $DMG_PATH. Called twice: once for the notary
# submission and again after the .app has been stapled, so the bundle inside the
# DMG carries its own ticket. Positions here must agree with the renderer.
make_dmg() {
    rm -f "$DMG_PATH"
    local stage
    stage="$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")"
    ditto "$BUILD_DIR/Release/$APP_NAME" "$stage/$APP_NAME"
    create-dmg \
        --volname "$VOLUME_NAME" \
        --volicon "$BUILD_DIR/Release/$APP_NAME/Contents/Resources/AppIcon.icns" \
        --background "$ARTWORK/background.png" \
        --window-pos 240 180 --window-size 720 468 \
        --icon-size 112 --text-size 14 \
        --icon "$APP_NAME" 200 218 --hide-extension "$APP_NAME" \
        --app-drop-link 520 218 \
        --format UDZO --filesystem HFS+ --no-internet-enable \
        "$DMG_PATH" "$stage"
    rm -rf "$stage"
}

echo "==> Creating DMG..."
make_dmg

# Notarize + staple. Credentials (App Store Connect API key path, key ID, issuer UUID) live
# OUTSIDE the repo in `scripts/.notary-config.local` (gitignored). That file must define
# NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER. See `scripts/.notary-config.example` for the
# template. Set NOTARIZE=0 to skip the notary loop entirely (fast local iteration).
#
# After Accepted: stapler the .app, then RE-PACKAGE the DMG so the .app inside it also
# carries its own ticket (offline-launch trust). Without the re-package, only the DMG
# container is stapled and `stapler validate` on the extracted .app fails.
NOTARY_CONFIG="$SCRIPT_DIR/.notary-config.local"

if [ "${NOTARIZE:-1}" != "0" ]; then
    if [ ! -f "$NOTARY_CONFIG" ]; then
        echo "==> WARN: $NOTARY_CONFIG missing — skipping notarization."
        echo "    Copy scripts/.notary-config.example, fill in your creds, save as .notary-config.local."
    else
        # shellcheck disable=SC1090
        source "$NOTARY_CONFIG"
        if [ ! -f "${NOTARY_KEY:-}" ]; then
            echo "==> WARN: NOTARY_KEY ($NOTARY_KEY) not found on disk — skipping notarization."
            exit 0
        fi
        if [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER:-}" ]; then
            echo "==> WARN: NOTARY_KEY_ID / NOTARY_ISSUER unset in $NOTARY_CONFIG — skipping notarization."
            exit 0
        fi
        echo "==> Submitting DMG to Apple notary service (this can take a few minutes)..."
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
            --wait 2>&1 | tee "$NOTARY_LOG"
        STATUS=$(grep -E "^\s*status:" "$NOTARY_LOG" | tail -1 | awk '{print $2}')
        if [ "$STATUS" != "Accepted" ]; then
            echo "==> ERROR: notarization status was '$STATUS', expected 'Accepted'."
            echo "    Fetch full log with the credentials in your notary config:"
            SUBMIT_ID=$(grep -E "^\s*id:" "$NOTARY_LOG" | head -1 | awk '{print $2}')
            echo "    xcrun notarytool log $SUBMIT_ID --key \"\$NOTARY_KEY\" --key-id \"\$NOTARY_KEY_ID\" --issuer \"\$NOTARY_ISSUER\""
            exit 1
        fi

        echo "==> Stapling .app and re-packaging DMG (so the .app inside is also stapled)..."
        xcrun stapler staple "$BUILD_DIR/Release/$APP_NAME" 2>&1 | tail -1

        # Re-create the DMG with the now-stapled .app so users get offline-launch-ready bundles.
        make_dmg

        echo "==> Re-submitting repackaged DMG (hash changed) and stapling..."
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
            --wait 2>&1 | tee "$NOTARY_LOG"
        STATUS=$(grep -E "^\s*status:" "$NOTARY_LOG" | tail -1 | awk '{print $2}')
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
