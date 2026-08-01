#!/usr/bin/env bash
# Notarize a signed DroidMate DMG with Apple.
#
# Prerequisites:
#   1. Apple Developer Program membership
#   2. Developer ID Application certificate in Keychain
#   3. App-specific password for notarytool (appleid.apple.com → App-Specific Passwords)
#
# Usage:
#   export APPLE_ID="you@example.com"
#   export TEAM_ID="ABCD123456"
#   export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # or use keychain profile
#   # optional: NOTARY_PROFILE=AC_PASSWORD if already stored:
#   #   xcrun notarytool store-credentials AC_PASSWORD --apple-id ... --team-id ... --password ...
#
#   ./scripts/notarize.sh                      # notarize build/DroidMate-<VERSION>.dmg
#   ./scripts/notarize.sh path/to/file.dmg
#   VERSION=0.1.0 ./scripts/notarize.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.2.5}"
DMG="${1:-$ROOT/build/DroidMate-$VERSION.dmg}"
APP="$ROOT/build/DroidMate.app"
PROFILE="${NOTARY_PROFILE:-}"

if [[ ! -f "$DMG" ]]; then
    echo "✗ DMG not found: $DMG"
    echo "  Build first:  CODESIGN_IDENTITY=\"Developer ID Application: …\" ./scripts/build-dmg.sh"
    exit 1
fi

echo "▶ checking Developer ID signature on $DMG / app"
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! grep -q "Authority=Developer ID Application:" <<<"$SIGN_INFO"; then
    echo "✗ App is not signed with Developer ID Application."
    echo "  Rebuild with:  export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶ submitting to Apple notary service (can take several minutes)…"
if [[ -n "$PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait
else
    echo "✗ Set credentials first:"
    echo "  export APPLE_ID=you@example.com"
    echo "  export TEAM_ID=YOURTEAMID"
    echo "  export APP_PASSWORD='app-specific-password'"
    echo "  # or: export NOTARY_PROFILE=AC_PASSWORD  (after store-credentials)"
    exit 1
fi

echo "▶ stapling ticket"
xcrun stapler staple "$DMG"
if [[ -d "$APP" ]]; then
    xcrun stapler staple "$APP"
fi

echo "▶ Gatekeeper assess"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"

echo ""
echo "✓ Notarization complete"
echo "  Distribute: $DMG"
echo "  Users can double-click without the malware warning."
