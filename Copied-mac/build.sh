#!/bin/bash
set -e

APP_NAME="Copied"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
FINGERPRINT="$BUILD_DIR/.source_fingerprint"

SOURCES=(
    ContentKind.swift
    ContentDetection.swift
    PluginActionTemplate.swift
    PluginManifest.swift
    PluginAction.swift
    PluginLoader.swift
    DetectionRegistry.swift
    Detectors/ColorDetector.swift
    Detectors/URLDetector.swift
    Detectors/FilePathDetector.swift
    Detectors/MathExpressionDetector.swift
    Detectors/DateTimeDetector.swift
    Detectors/ChineseCharDetector.swift
    Detectors/EnglishPhraseDetector.swift
    Detectors/HTMLDetector.swift
    Detectors/SwiftDetector.swift
    Detectors/PythonDetector.swift
    Detectors/JavaScriptDetector.swift
    Detectors/CSSDetector.swift
    Detectors/CodeDetector.swift
    TypeSettingsView.swift
    CopiedApp.swift
    ClipboardMonitor.swift
    SourceAppDetector.swift
    ClipboardAction.swift
    FilePreviewGenerator.swift
    SettingsView.swift
    ToastView.swift
    ToastViewModel.swift
    ToastWindowController.swift
    TranslateAction.swift
)

echo "🔨 Building Copied..."

# ── Fingerprint check (skip compilation if nothing changed) ──
NPROC=$(sysctl -n hw.ncpu)
NEW_FP=$(shasum -a 256 "${SOURCES[@]}" 2>/dev/null | shasum -a 256)
OLD_FP=$(cat "$FINGERPRINT" 2>/dev/null || echo "")

if [[ "$NEW_FP" == "$OLD_FP" ]] && [[ -f "$MACOS_DIR/$APP_NAME" ]]; then
    echo "   no changes, skipping compilation"
    exit 0
fi

# ── Clean & compile ─────────────────────────────────────────
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swiftc \
    -num-threads "$NPROC" \
    -o "$MACOS_DIR/$APP_NAME" \
    -target arm64-apple-macosx26.0 \
    -framework SwiftUI \
    -framework AppKit \
    -framework QuickLookThumbnailing \
    -framework ServiceManagement \
    -framework Translation \
    "${SOURCES[@]}"

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc code sign (required by SMAppService for login item registration)
codesign -s - -f "$APP_BUNDLE" 2>/dev/null || true

# Store fingerprint for next build
echo "$NEW_FP" > "$FINGERPRINT"

echo ""
echo "✅ Build complete!"
echo "   App: $APP_BUNDLE"
echo ""
echo "   运行:  open $APP_BUNDLE"
echo "   或直接双击 Finder 中的 Copied.app"
