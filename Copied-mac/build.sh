#!/bin/bash
set -e

APP_NAME="Copied"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "🔨 Building Copied..."

# Clean
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Compile all Swift sources
swiftc \
    -o "$MACOS_DIR/$APP_NAME" \
    -target arm64-apple-macosx26.0 \
    -framework SwiftUI \
    -framework AppKit \
    CopiedApp.swift \
    ClipboardMonitor.swift \
    SourceAppDetector.swift \
    ToastView.swift \
    ToastViewModel.swift \
    ToastWindowController.swift

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo ""
echo "✅ Build complete!"
echo "   App: $APP_BUNDLE"
echo ""
echo "   运行:  open $APP_BUNDLE"
echo "   或直接双击 Finder 中的 Copied.app"
