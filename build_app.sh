#!/bin/bash
set -euo pipefail

# ==============================================================================
# RemminaMac Build Script
# Builds a proper macOS .app bundle from the Swift package
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="RemminaMac"
BUNDLE_DIR="$PROJECT_DIR/dist/${APP_NAME}.app"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.png"
RESOURCES_DIR="$PROJECT_DIR/Resources"

echo "🔨 Building RemminaMac..."
echo ""

# Step 1: Build release binary
echo "📦 Step 1/5: Compiling release binary..."
swift build -c release 2>&1 | tail -3
BINARY="$BUILD_DIR/release/${APP_NAME}"

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed. Binary not found at $BINARY"
    exit 1
fi

echo "✅ Binary compiled successfully"
echo ""

# Step 2: Create .app bundle structure
echo "📁 Step 2/5: Creating app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "$RESOURCES_DIR/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Stamp the build number from the commit count so every distributed build has a
# strictly higher CFBundleVersion than the last. macOS uses this value to decide
# whether an install is newer; a static value means an update may be ignored.
# CFBundleShortVersionString (the human-facing "0.9.0") is left as authored.
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$BUNDLE_DIR/Contents/Info.plist" >/dev/null
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$BUNDLE_DIR/Contents/Info.plist")"
echo "   Version: $SHORT_VERSION (build $BUILD_NUMBER)"

# Write PkgInfo
echo -n "APPL????" > "$BUNDLE_DIR/Contents/PkgInfo"

echo "✅ Bundle structure created"
echo ""

# Step 3: Create icon
echo "🎨 Step 3/5: Creating app icon..."
if [ -f "$ICON_SOURCE" ]; then
    ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    # Ensure source is proper PNG at 1024x1024
    ICON_WORK="/tmp/remmina_icon_1024.png"
    sips -s format png "$ICON_SOURCE" --out "$ICON_WORK" > /dev/null 2>&1
    sips -z 1024 1024 "$ICON_WORK" --out "$ICON_WORK"   > /dev/null 2>&1

    # Generate all required icon sizes
    sips -z 16 16     "$ICON_WORK" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     "$ICON_WORK" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     "$ICON_WORK" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     "$ICON_WORK" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   "$ICON_WORK" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   "$ICON_WORK" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   "$ICON_WORK" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   "$ICON_WORK" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   "$ICON_WORK" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null 2>&1
    cp "$ICON_WORK"                      "$ICONSET_DIR/icon_512x512@2x.png"

    # Convert to .icns
    iconutil -c icns "$ICONSET_DIR" -o "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR" "$ICON_WORK"
    echo "✅ App icon created"
else
    echo "⚠️  Icon source not found at $ICON_SOURCE — skipping icon"
    echo "   Place a 1024x1024 PNG at Resources/AppIcon.png and rebuild"
fi
echo ""

# Step 4: Copy entitlements (for reference)
echo "🔐 Step 4/5: Setting up entitlements..."
if [ -f "$RESOURCES_DIR/RemminaMac.entitlements" ]; then
    cp "$RESOURCES_DIR/RemminaMac.entitlements" "$BUNDLE_DIR/Contents/Resources/"
    echo "✅ Entitlements copied"
else
    echo "⚠️  No entitlements file found"
fi
echo ""

# Step 5: Code sign (ad-hoc for local use)
echo "🔏 Step 5/5: Code signing (ad-hoc)..."
# Identity: honour CODESIGN_IDENTITY if the caller has a real Developer ID,
# otherwise fall back to ad-hoc ("-").
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --deep --sign "$SIGN_IDENTITY")

if [ -f "$RESOURCES_DIR/RemminaMac.entitlements" ]; then
    ENTITLEMENTS_TO_USE="$RESOURCES_DIR/RemminaMac.entitlements"

    if [ "$SIGN_IDENTITY" = "-" ]; then
        # The entitlements file declares a keychain access group prefixed with
        # $(AppIdentifierPrefix). That is an Xcode build variable; codesign does
        # NOT substitute it, so an ad-hoc build would ship the literal string as
        # its entitlement value. A keychain-access-group with no valid team
        # prefix is rejected by the kernel at spawn time, and the app fails to
        # launch with "Launchd job spawn failed" / "can't be opened".
        #
        # The access group is inert without a Team ID anyway — Keychain falls
        # back to the binary's own default access group — so strip the key for
        # ad-hoc builds and keep the file intact for real Developer ID signing.
        ENTITLEMENTS_TO_USE="$BUILD_DIR/RemminaMac-adhoc.entitlements"
        cp "$RESOURCES_DIR/RemminaMac.entitlements" "$ENTITLEMENTS_TO_USE"
        /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" \
            "$ENTITLEMENTS_TO_USE" >/dev/null 2>&1 || true
        echo "   Ad-hoc build: keychain-access-groups stripped (needs a Team ID)"
    fi

    SIGN_FLAGS+=(--entitlements "$ENTITLEMENTS_TO_USE")
fi
codesign "${SIGN_FLAGS[@]}" "$BUNDLE_DIR" 2>&1 || {
    echo "⚠️  Code signing failed (app will still work locally)"
}
echo "✅ Code signed"
echo ""

# Summary
BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
echo "=============================================="
echo "✅ Build complete!"
echo ""
echo "  App:      $BUNDLE_DIR"
echo "  Size:     $BUNDLE_SIZE"
echo ""
echo "  To run:   open \"$BUNDLE_DIR\""
echo "  To install: cp -r \"$BUNDLE_DIR\" /Applications/"
echo "=============================================="
