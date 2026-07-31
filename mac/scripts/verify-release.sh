#!/usr/bin/env bash
# Release gate: unit tests + MCP build + server jar present + optional DMG.
#
# Usage:
#   ./scripts/verify-release.sh           # tests + MCP + jar check
#   ./scripts/verify-release.sh --dmg     # also package DMG
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
cd "$ROOT"

MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        -h|--help)
            echo "Usage: $0 [--dmg]"
            exit 0
            ;;
    esac
done

echo "▶ swift test"
swift test

echo "▶ swift build --product DroidMateMCP -c release"
swift build --product DroidMateMCP -c release

JAR="$ROOT/Resources/droidmate-server.jar"
if [[ -f "$JAR" ]]; then
    echo "✓ server jar: $JAR ($(wc -c <"$JAR" | tr -d ' ') bytes)"
else
    echo "✗ droidmate-server.jar missing at mac/Resources/droidmate-server.jar"
    exit 1
fi

BIN_OK=1
for b in adb scrcpy scrcpy-server; do
    if [[ ! -e "$ROOT/Sources/DroidMate/Bin/$b" && ! -e "$ROOT/Resources/Bin/$b" ]]; then
        # Bundled under Sources/DroidMate/Bin in this tree.
        if [[ ! -e "$ROOT/Sources/DroidMate/Bin/$b" ]]; then
            echo "⚠ optional bin not found: $b (mirror may be limited)"
            BIN_OK=0
        fi
    fi
done
if [[ "$BIN_OK" -eq 1 ]]; then
    echo "✓ scrcpy/adb bundle present under Sources/DroidMate/Bin"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    echo "▶ build-dmg.sh"
    ./scripts/build-dmg.sh
    VERSION="${VERSION:-0.2.1}"
    DMG="$ROOT/build/DroidMate-$VERSION.dmg"
    if [[ -f "$DMG" ]]; then
        echo "✓ DMG: $DMG"
    else
        echo "✗ expected DMG not found: $DMG"
        exit 1
    fi
fi

echo ""
echo "✓ verify-release OK"
echo "  App tests + MCP release binary + server jar ready."
