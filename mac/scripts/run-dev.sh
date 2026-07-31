#!/usr/bin/env bash
# Build + run DroidMate as a proper .app bundle for development.
#
# Unlike `swift run` (bare binary), this creates a minimal .app structure so
# that Bundle.main resolves correctly — localizations, bundled adb, and the
# server JAR all work the same as a production build.
#
# Usage:
#   ./scripts/run-dev.sh           # debug build + run
#   ./scripts/run-dev.sh release   # release build + run

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
FLAGS=""
if [[ "${1:-}" == "release" ]]; then
    CONFIG="release"
    FLAGS="-c release"
fi

echo "▶ swift build $FLAGS"
swift build $FLAGS

BIN_DIR="$(swift build $FLAGS --show-bin-path)"
APP_DIR="$ROOT/.build/$CONFIG-app/DroidMate.app"

echo "▶ assembling dev .app at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Executable
cp "$BIN_DIR/DroidMate" "$APP_DIR/Contents/MacOS/DroidMate"
chmod +x "$APP_DIR/Contents/MacOS/DroidMate"

# SPM module bundle (contains zh-Hans.lproj + Bin/adb)
if [[ -d "$BIN_DIR/DroidMate_DroidMate.bundle" ]]; then
    cp -R "$BIN_DIR/DroidMate_DroidMate.bundle/"* "$APP_DIR/Contents/Resources/"
fi

# Fix lproj casing: SPM outputs lowercase zh-hans.lproj, but macOS needs
# zh-Hans.lproj (capital H) for locale matching to work.
if [[ -d "$APP_DIR/Contents/Resources/zh-hans.lproj" ]]; then
    mv "$APP_DIR/Contents/Resources/zh-hans.lproj" "$APP_DIR/Contents/Resources/zh-Hans.lproj"
fi

# Create an empty en.lproj so the development locale (en) has a base file.
# Without this, macOS treats the bundle as unlocalized and ignores zh-Hans.
if [[ ! -d "$APP_DIR/Contents/Resources/en.lproj" ]]; then
    mkdir -p "$APP_DIR/Contents/Resources/en.lproj"
    echo '{}' | plutil -convert binary1 -o "$APP_DIR/Contents/Resources/en.lproj/Localizable.strings" -
fi

# Server JAR
if [[ -f "$ROOT/Resources/droidmate-server.jar" ]]; then
    cp "$ROOT/Resources/droidmate-server.jar" "$APP_DIR/Contents/Resources/"
fi

# Brand AppIcon.icns — required so Dock applies the continuous-corner mask.
# A raw PNG assigned at runtime shows as a hard square next to real app icons.
ICON_SRC=""
for cand in \
    "$ROOT/Sources/DroidMate/Resources/Brand/AppIcon.png" \
    "$ROOT/Resources/Brand/AppIcon.png" \
    "$APP_DIR/Contents/Resources/Brand/AppIcon.png" \
    "$APP_DIR/Contents/Resources/AppIcon.png"
do
    if [[ -f "$cand" ]]; then ICON_SRC="$cand"; break; fi
done
if [[ -n "$ICON_SRC" ]]; then
    echo "▶ building AppIcon.icns from $(basename "$ICON_SRC")"
    ICONSET=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
    mkdir -p "$APP_DIR/Contents/Resources/Brand"
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/Brand/AppIcon.png"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "⚠ no Brand/AppIcon.png — Dock icon may look square"
fi

# Info.plist — CFBundleLocalizations declares the supported languages so the
# runtime localizes even for bare SPM bundles. CFBundleDevelopmentRegion=en
# means English is the default; zh-Hans is used when the system is Chinese.
# CFBundleIconFile must point at AppIcon.icns for proper Dock corner mask.
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>DroidMate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.droidmate.dev</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DroidMate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.1-dev</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DroidMate uses the local network to connect to Android devices.</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>DroidMate shows notifications when transfers complete.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc sign so Gatekeeper is happy with nested resources
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "▶ launching"
# Clear icon cache for this bundle path (dev rebuilds reuse the same path)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
exec open "$APP_DIR"
