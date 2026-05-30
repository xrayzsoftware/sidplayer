#!/usr/bin/env bash
# Build a Release .dmg for distribution.
# Run from the repo root: ./scripts/dmg.sh
# Output: build/SID Player.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SIDPlayer.xcodeproj"
SCHEME="SIDPlayer"
APP_NAME="SID Player"
BUILD_DIR="build"
DMG_DIR="${BUILD_DIR}/dmg-stage"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

# Regenerate Xcode project if xcodegen is available.
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
fi

echo "▸ Building Release…"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    build \
    | tail -3

# Locate the built .app.
BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*Release*${APP_NAME}.app" -type d 2>/dev/null \
    | head -1)

if [[ -z "${BUILT_APP}" ]]; then
    echo "✗ Couldn't find the built .app under DerivedData."
    exit 1
fi

echo "▸ Staging DMG contents…"
mkdir -p "${BUILD_DIR}"
rm -rf "${DMG_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_DIR}"
ditto "${BUILT_APP}" "${DMG_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_DIR}/Applications"

echo "▸ Creating DMG…"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" \
    > /dev/null

rm -rf "${DMG_DIR}"

SIZE=$(du -h "${DMG_PATH}" | cut -f1 | xargs)
echo "✓ ${DMG_PATH} (${SIZE})"
