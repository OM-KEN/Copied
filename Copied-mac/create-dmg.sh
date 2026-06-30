#!/bin/bash
set -e

# ── Config ──────────────────────────────────────────────────
APP_NAME="Copied"
APP_PATH=".build/${APP_NAME}.app"
DMG_PATH=".build/${APP_NAME}.dmg"
TMP_DMG=".build/tmp.dmg"
STAGING=".build/dmg_staging"
VOL_NAME="Copied"
DMG_SIZE_MB=80

# ── 1. Build the app ────────────────────────────────────────
echo "🔨 Building ${APP_NAME}..."
./build.sh

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — $APP_PATH not found"
    exit 1
fi

# ── Background image (optional, skip if not found) ──
BG_PNG=".build/dmg_background.png"
HAS_BG=false
if [ -f "$BG_PNG" ]; then
    echo "🎨 Using DMG background: $BG_PNG"
    HAS_BG=true
else
    echo "🎨 No DMG background (optional, place at $BG_PNG)"
fi

# ── 2. Prepare staging directory ────────────────────────────
echo "📦 Preparing DMG staging directory..."
rm -rf "$STAGING" "$DMG_PATH" "$TMP_DMG"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Copy background image (hidden .background folder)
if $HAS_BG; then
    mkdir -p "$STAGING/.background"
    cp "$BG_PNG" "$STAGING/.background/background.png"
fi

# ── 3. Create read-write DMG ────────────────────────────────
echo "💿 Creating temporary DMG..."
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE_MB}m \
    "$TMP_DMG" > /dev/null

# ── 4. Mount and configure Finder window ────────────────────
echo "🖥  Configuring DMG layout..."

# Detach any stale mount
hdiutil detach "/Volumes/${VOL_NAME}" -force > /dev/null 2>&1 || true

DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" 2>&1 | \
      grep '^/dev/' | head -1 | awk '{print $1}')

if [ -z "$DEV" ]; then
    echo "❌ Failed to mount DMG"
    exit 1
fi

MOUNT_POINT="/Volumes/${VOL_NAME}"

# Wait for mount to settle
sleep 0.5

# Remove .DS_Store that cp may have brought over, and any hidden files
rm -f "$MOUNT_POINT/.DS_Store" 2>/dev/null || true

# Use AppleScript to configure the Finder window
osascript <<ENDSCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 640, 440}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "${APP_NAME}.app" of container window to {110, 120}
        set position of item "Applications" of container window to {330, 120}
        set background picture of theViewOptions to file ".background:background.png"
        close
        open
        update without registering applications
        delay 0.5
        close
    end tell
end tell
ENDSCRIPT

# ── 5. Unmount ──────────────────────────────────────────────
echo "📎 Finalizing DMG..."
hdiutil detach "$DEV" -force > /dev/null 2>&1

# ── 6. Convert to compressed read-only ──────────────────────
echo "🗜  Compressing DMG..."
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" > /dev/null

# ── 8. Cleanup ──────────────────────────────────────────────
rm -f "$TMP_DMG"
rm -rf "$STAGING"

echo ""
echo "✅ DMG created: ${DMG_PATH}"
echo "   Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "   双击 ${DMG_PATH} 即可测试安装体验。"
