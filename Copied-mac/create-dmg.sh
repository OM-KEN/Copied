#!/bin/bash
set -e

# ── Config ──────────────────────────────────────────────────
APP_NAME="Copied"
APP_PATH=".build/${APP_NAME}.app"
DMG_PATH=".build/${APP_NAME}.dmg"
SETTINGS_PY="dmg_settings.py"

# ── 1. Build the app ────────────────────────────────────────
echo "🔨 Building ${APP_NAME}..."
./build.sh

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — $APP_PATH not found"
    exit 1
fi

# ── 2. Check prerequisites ──────────────────────────────────
if ! python3 -c "import dmgbuild" 2>/dev/null; then
    echo "❌ dmgbuild not installed. Run: pip3 install 'dmgbuild>=1.6.5'"
    exit 1
fi

BG_PNG=".build/dmg_background.png"
if [ -f "$BG_PNG" ]; then
    echo "🎨 Using DMG background: $BG_PNG"
else
    echo "🎨 No DMG background (place at $BG_PNG for background image)"
fi

# ── 3. Build DMG with dmgbuild ───────────────────────────────
echo "💿 Creating DMG..."
rm -f "$DMG_PATH"

python3 -m dmgbuild -s "$SETTINGS_PY" \
    "$APP_NAME" \
    "$DMG_PATH"

echo ""
echo "✅ DMG created: ${DMG_PATH}"
echo "   Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "   双击 ${DMG_PATH} 即可测试安装体验。"
