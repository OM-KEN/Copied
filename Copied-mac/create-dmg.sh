#!/bin/bash
set -e

# ── Config ──────────────────────────────────────────────────
APP_NAME="Copied"
APP_PATH=".build/${APP_NAME}.app"
DMG_PATH=".build/${APP_NAME}.dmg"
SETTINGS_PY="dmg_settings.py"
BG_PNG="dmg_background.png"

# ── 1. Build the app ────────────────────────────────────────
echo "🔨 Building ${APP_NAME}..."
./build.sh

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed — $APP_PATH not found"
    exit 1
fi

# ── 2. Check prerequisites ──────────────────────────────────
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' 2>/dev/null; then
    echo "❌ Python 3.10+ required. Run: brew install python"
    exit 1
fi

if ! python3 -c 'from importlib.metadata import version; raise SystemExit(version("dmgbuild") != "1.6.7")' 2>/dev/null; then
    echo "❌ dmgbuild 1.6.7 required. Run: python3 -m pip install --upgrade --user --break-system-packages 'dmgbuild==1.6.7'"
    exit 1
fi

if [ ! -f "$BG_PNG" ]; then
    echo "❌ DMG background not found: $BG_PNG"
    exit 1
fi

echo "🎨 Using DMG background: $BG_PNG"

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
