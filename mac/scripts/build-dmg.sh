#!/usr/bin/env bash
# Build DroidMate.app and package as a distributable DMG.
#
# Usage:
#   ./scripts/build-dmg.sh              # release build + .app + .dmg
#   ./scripts/build-dmg.sh skip-build   # reuse existing release binary
#   VERSION=0.2.0 BUILD=42 ./scripts/build-dmg.sh
#
# Output:
#   mac/build/DroidMate.app
#   mac/build/DroidMate-<version>.dmg
#
# Prerequisites:
#   - Xcode CLT (swift, hdiutil, codesign, sips, iconutil)
#   - droidmate-server.jar at mac/Resources/droidmate-server.jar (vendored)
#
# Signing:
#   Default is ad-hoc (-). For public distribution set:
#     CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   Then notarize (see mac/RELEASE.md).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="DroidMate"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="${VERSION:-0.2.5}"
BUILD_NUMBER="${BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-com.droidmate.app}"
# Empty / "-" = ad-hoc. Set CODESIGN_IDENTITY for Developer ID.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$ROOT"

# ── 0. Prerequisites ────────────────────────────────────────────────
if [[ ! -f "$ROOT/Resources/droidmate-server.jar" ]]; then
    echo "✗ droidmate-server.jar missing at mac/Resources/droidmate-server.jar"
    echo "  The device-side Server jar is vendored in-repo (no Android module)."
    echo "  Restore or place droidmate-server.jar under mac/Resources/ before packaging."
    exit 1
fi

# ── 1. Release build ─────────────────────────────────────────────────
if [[ "${1:-}" != "skip-build" ]]; then
    echo "▶ swift build -c release"
    swift build -c release
fi

RELEASE_BIN="$ROOT/.build/release/$APP_NAME"
SPM_BUNDLE="$ROOT/.build/release/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -f "$RELEASE_BIN" ]]; then
    echo "✗ Release binary not found at $RELEASE_BIN"
    exit 1
fi
if [[ ! -d "$SPM_BUNDLE" ]]; then
    echo "✗ SPM resource bundle not found at $SPM_BUNDLE"
    exit 1
fi

# ── 2. Assemble .app ─────────────────────────────────────────────────
echo "▶ assembling $APP_BUNDLE (v$VERSION build $BUILD_NUMBER)"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$RELEASE_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Strip local symbols for a smaller, cleaner release binary.
if command -v strip >/dev/null; then
    strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

cp "$ROOT/Resources/droidmate-server.jar" "$APP_BUNDLE/Contents/Resources/"

mkdir -p "$APP_BUNDLE/Contents/Resources/Bin"
# Copy entire Bin/ (adb + scrcpy portable + scrcpy-server)
if [[ -d "$SPM_BUNDLE/Bin" ]]; then
    cp -R "$SPM_BUNDLE/Bin/." "$APP_BUNDLE/Contents/Resources/Bin/"
elif [[ -d "$ROOT/Sources/DroidMate/Bin" ]]; then
    cp -R "$ROOT/Sources/DroidMate/Bin/." "$APP_BUNDLE/Contents/Resources/Bin/"
fi
if [[ -f "$APP_BUNDLE/Contents/Resources/Bin/adb" ]]; then
    chmod +x "$APP_BUNDLE/Contents/Resources/Bin/adb"
else
    echo "⚠ bundled adb missing — users will need system adb or Homebrew"
fi
if [[ -f "$APP_BUNDLE/Contents/Resources/Bin/scrcpy" ]]; then
    chmod +x "$APP_BUNDLE/Contents/Resources/Bin/scrcpy"
    echo "  bundled scrcpy + server ready"
else
    echo "⚠ bundled scrcpy missing — screen mirror will need Homebrew scrcpy"
fi

# Localizations
if [[ -d "$SPM_BUNDLE/zh-hans.lproj" ]]; then
    cp -R "$SPM_BUNDLE/zh-hans.lproj" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"
elif [[ -d "$SPM_BUNDLE/zh-Hans.lproj" ]]; then
    cp -R "$SPM_BUNDLE/zh-Hans.lproj" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"
fi
mkdir -p "$APP_BUNDLE/Contents/Resources/en.lproj"
if [[ ! -f "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings" ]]; then
    echo '{}' | plutil -convert binary1 -o "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings" -
fi

# Brand assets (designed AppIcon) — prefer Sources/Resources over SPM bundle
# so packaging always picks up the latest full-bleed icon without a full rebuild.
mkdir -p "$APP_BUNDLE/Contents/Resources/Brand"
if [[ -f "$ROOT/Sources/DroidMate/Resources/Brand/AppIcon.png" ]]; then
    cp "$ROOT/Sources/DroidMate/Resources/Brand/AppIcon.png" "$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png"
elif [[ -f "$ROOT/Resources/Brand/AppIcon.png" ]]; then
    cp "$ROOT/Resources/Brand/AppIcon.png" "$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png"
elif [[ -f "$SPM_BUNDLE/Brand/AppIcon.png" ]]; then
    cp "$SPM_BUNDLE/Brand/AppIcon.png" "$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png"
fi

# ── 3. App icon (.icns) ──────────────────────────────────────────────
echo "▶ generating AppIcon.icns"
ICON_WORK="$BUILD_DIR/icon-work"
rm -rf "$ICON_WORK"
mkdir -p "$ICON_WORK/AppIcon.iconset"
PNG_SRC="$ICON_WORK/icon-1024.png"

# Prefer designed brand PNG, then CLI export from binary.
if [[ -f "$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png" ]]; then
    sips -z 1024 1024 "$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png" --out "$PNG_SRC" >/dev/null
elif "$RELEASE_BIN" --export-icon "$PNG_SRC" 2>/dev/null; then
    :
elif "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --export-icon "$PNG_SRC" 2>/dev/null; then
    :
else
    echo "⚠ icon export failed — app will use runtime-generated Dock icon only"
    PNG_SRC=""
fi

if [[ -n "$PNG_SRC" && -f "$PNG_SRC" ]]; then
    ICONSET="$ICON_WORK/AppIcon.iconset"
    sips -z 16 16     "$PNG_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32     "$PNG_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$PNG_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64     "$PNG_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$PNG_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256   "$PNG_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$PNG_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512   "$PNG_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$PNG_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$PNG_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    # iconutil rejects RGB-only (no alpha) PNGs on some toolchains.
    python3 - "$ICONSET" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path
try:
    from PIL import Image
except ImportError:
    sys.exit(0)
root = Path(sys.argv[1])
for f in root.glob("*.png"):
    im = Image.open(f)
    if im.mode != "RGBA":
        im.convert("RGBA").save(f)
PY
    if iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"; then
        echo "  AppIcon.icns ready (brand monogram)"
    else
        echo "  ⚠ iconutil failed — continuing without AppIcon.icns"
    fi
fi

# ── 4. Info.plist ────────────────────────────────────────────────────
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
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
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © DroidMate contributors. MIT License.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DroidMate uses the local network to discover and connect to Android devices over Wi-Fi.</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>DroidMate shows local notifications when file transfers complete and when mirroring Android notifications.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# ── 5. Codesign ──────────────────────────────────────────────────────
echo "▶ codesign (identity: $CODESIGN_IDENTITY)"
ENTITLEMENTS="$ROOT/entitlements.plist"
SIGN_OPTIONS=(--force --options runtime)
APP_SIGN_OPTIONS=(--force --options runtime)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    SIGN_OPTIONS+=(--timestamp)
    APP_SIGN_OPTIONS+=(--timestamp)
    if [[ -f "$ENTITLEMENTS" ]]; then
        APP_SIGN_OPTIONS+=(--entitlements "$ENTITLEMENTS")
    fi
fi
# Nested binaries must be signed first. App-only entitlements do not belong on
# adb or scrcpy.
if [[ -f "$APP_BUNDLE/Contents/Resources/Bin/adb" ]]; then
    codesign "${SIGN_OPTIONS[@]}" --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Resources/Bin/adb" 2>&1 | sed 's/^/  /'
fi
if [[ -f "$APP_BUNDLE/Contents/Resources/Bin/scrcpy" ]]; then
    codesign "${SIGN_OPTIONS[@]}" --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE/Contents/Resources/Bin/scrcpy" 2>&1 | sed 's/^/  /'
fi
# scrcpy-server is device-side data, not executable macOS code.
codesign "${APP_SIGN_OPTIONS[@]}" --sign "$CODESIGN_IDENTITY" \
    "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "▶ verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "  ⚠ ad-hoc only — Gatekeeper will warn strangers. For distribution:"
    echo "    export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
    echo "    ./scripts/build-dmg.sh && ./scripts/notarize.sh"
fi

# ── 6. DMG background ────────────────────────────────────────────────
echo "▶ generating DMG background"
DMG_BG="$BUILD_DIR/dmg-background.png"
ICON_FOR_BG="$APP_BUNDLE/Contents/Resources/Brand/AppIcon.png"
if [[ ! -f "$ICON_FOR_BG" ]]; then
    ICON_FOR_BG="$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi
if [[ ! -f "$ICON_FOR_BG" ]]; then
    ICON_FOR_BG="$ROOT/Sources/DroidMate/Resources/Brand/AppIcon.png"
fi
swift "$ROOT/scripts/generate-dmg-background.swift" "$DMG_BG" "$ICON_FOR_BG"

# ── 7. Package styled DMG (programmatic .DS_Store) ───────────────────
# Finder only honours custom icon positions + background when .DS_Store
# is written on a read-write image, then converted to UDZO.
#
# AppleScript (and brew create-dmg, which relies on it) is unreliable on
# modern macOS: backgroundType often stays 0 (plain white). We write
# .DS_Store with ds_store + mac_alias instead (dmgbuild technique):
#   backgroundType=2 + backgroundImageAlias → .background.png
#
# Volume name has NO spaces. Always eject leftover volumes first.
VOL_NAME="DroidMate"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
echo "▶ creating styled DMG → $DMG"
rm -f "$DMG" "$RW_DMG"

echo "▶ clearing stale DroidMate volumes"
for vol in /Volumes/DroidMate* /Volumes/dmg.*; do
    [[ -e "$vol" ]] || continue
    # only eject dmg.* if it looks like our interstitial
    if [[ "$vol" == /Volumes/dmg.* ]]; then
        # skip unrelated random mounts unless empty-ish — still force-detach our leftovers
        :
    fi
    echo "  eject $vol"
    hdiutil detach "$vol" -force >/dev/null 2>&1 \
        || diskutil unmount force "$vol" >/dev/null 2>&1 \
        || true
done

# Icon positions match generate-dmg-background.swift drop-zone centers:
#   App @ {180, 205} · Applications @ {540, 205}
# Window 720×440 matches background PNG 1:1.
ICON_X_APP=180
ICON_Y=205
ICON_X_APPS=540
WIN_W=720
WIN_H=440
ICON_SZ=88

# Keep DMG tooling out of the system Python (macOS runners enforce PEP 668).
DMG_PY_ENV="$BUILD_DIR/dmg-python"
DMG_PYTHON="$DMG_PY_ENV/bin/python3"
if ! "$DMG_PYTHON" -c "from ds_store import DSStore; from mac_alias import Alias" 2>/dev/null; then
    echo "▶ preparing isolated Python deps: ds_store mac_alias"
    rm -rf "$DMG_PY_ENV"
    python3 -m venv "$DMG_PY_ENV"
    "$DMG_PYTHON" -m pip install --disable-pip-version-check \
        'ds_store==1.3.3' 'mac_alias==2.2.3'
fi

echo "▶ creating RW disk image (HFS+, volname=$VOL_NAME)"
hdiutil create -size 100m -fs HFS+ -volname "$VOL_NAME" -o "$RW_DMG" >/dev/null

ATTACH_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")
MOUNT_DIR=$(echo "$ATTACH_OUT" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "✗ failed to mount RW DMG"
    echo "$ATTACH_OUT"
    exit 1
fi
DISK_NAME=$(basename "$MOUNT_DIR")
echo "  mounted at $MOUNT_DIR (disk: $DISK_NAME)"
if [[ "$DISK_NAME" != "$VOL_NAME" ]]; then
    echo "✗ unexpected mount name '$DISK_NAME' (wanted '$VOL_NAME')"
    echo "  Close other DroidMate volumes and retry."
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    exit 1
fi

# Payload — only the app + Applications symlink (no Install.txt clutter)
cp -R "$APP_BUNDLE" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Volume icon (optional)
if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
        SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
    fi
fi

# Background as hidden root file (.background.png) — dmgbuild convention.
# Folder form (.background/background.png) + AppleScript is flaky; alias to
# a root-level file works when written into .DS_Store programmatically.
cp "$DMG_BG" "$MOUNT_DIR/.background.png"

echo "▶ writing .DS_Store (backgroundType=2 + icon layout)"
"$DMG_PYTHON" "$ROOT/scripts/write-dmg-dsstore.py" \
    "$MOUNT_DIR" \
    "$MOUNT_DIR/.background.png" \
    --app-name "$APP_NAME.app" \
    --app-x "$ICON_X_APP" --app-y "$ICON_Y" \
    --apps-x "$ICON_X_APPS" --apps-y "$ICON_Y" \
    --icon-size "$ICON_SZ" \
    --text-size 12 \
    --win-x 200 --win-y 120 --win-w "$WIN_W" --win-h "$WIN_H"

# Verify layout artifacts
if [[ ! -f "$MOUNT_DIR/.DS_Store" ]]; then
    echo "✗ .DS_Store missing after write"
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    exit 1
fi
if [[ ! -f "$MOUNT_DIR/.background.png" ]]; then
    echo "✗ .background.png missing on volume"
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    exit 1
fi

# Sanity-check backgroundType in the written store
"$DMG_PYTHON" - <<PY
from ds_store import DSStore
with DSStore.open("$MOUNT_DIR/.DS_Store", "r") as d:
    icvp = None
    for e in d:
        if e.filename == "." and e.code == b"icvp":
            icvp = e.value
            break
    if not icvp or icvp.get("backgroundType") != 2:
        raise SystemExit(f"✗ backgroundType not 2: {icvp and icvp.get('backgroundType')}")
    if "backgroundImageAlias" not in icvp:
        raise SystemExit("✗ backgroundImageAlias missing from icvp")
    print(f"  verified icvp: backgroundType=2 iconSize={icvp.get('iconSize')} alias={len(icvp['backgroundImageAlias'])}B")
PY

# Remove Finder clutter that appears as icons on the installer window
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" "$MOUNT_DIR/.TemporaryItems" 2>/dev/null || true

sync
sleep 0.5
echo "▶ detaching volume"
if ! hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
fi
sleep 0.4

echo "▶ compressing → UDZO"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" 2>&1 | tail -6 | sed 's/^/  /'
rm -f "$RW_DMG"
rm -rf "$ICON_WORK"

if [[ ! -f "$DMG" ]]; then
    echo "✗ DMG was not created"
    exit 1
fi
hdiutil verify "$DMG" >/dev/null

# ── 8. Summary ───────────────────────────────────────────────────────
APP_SIZE=$(du -sh "$APP_BUNDLE" | awk '{print $1}')
DMG_SIZE=$(du -sh "$DMG" | awk '{print $1}')

echo ""
echo "✓ Release package ready"
echo "  App:     $APP_BUNDLE  ($APP_SIZE)"
echo "  DMG:     $DMG  ($DMG_SIZE)"
echo "  Version: $VERSION ($BUILD_NUMBER)"
echo "  Bundle:  $BUNDLE_ID"
echo "  Sign:    $CODESIGN_IDENTITY"
echo "  Window:  720×440 icon layout + brand B background"
echo ""
echo "Install: open the DMG → drag DroidMate → Applications → right-click Open (first time)."
echo "Notarization / Developer ID: see mac/RELEASE.md"
echo ""
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "⚠ Ad-hoc signature only — fine for testing, not ideal for wide distribution."
    echo "  Set CODESIGN_IDENTITY to your Developer ID for Gatekeeper-friendly builds."
fi
