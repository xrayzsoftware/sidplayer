#!/usr/bin/env bash
# Build a Release .dmg for distribution. The app is Developer ID-signed with
# the hardened runtime (unsigned/ad-hoc builds are rejected by Gatekeeper);
# use notarize.sh for the notarized version.
# Run from the repo root: ./scripts/dmg.sh
# Output: build/SID Player.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SIDPlayer.xcodeproj"
SCHEME="SIDPlayer"
APP_NAME="SID Player"
ENTITLEMENTS="App/SIDPlayer.entitlements"
BUILD_DIR="build"
DMG_DIR="${BUILD_DIR}/dmg-stage"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

# --- Resolve the Developer ID Application signing identity -------------------
# `|| true` keeps `set -e` from killing the script inside the substitution
# when grep finds nothing, so the guard below can print its help.
DEV_ID="${DEV_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/' || true)}"

if [[ -z "${DEV_ID}" ]]; then
    echo "✗ No 'Developer ID Application' identity found in your keychain."
    echo "  Create one: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application"
    echo "  Then re-run, or pass DEV_ID=\"Developer ID Application: Name (TEAMID)\"."
    exit 1
fi
echo "▸ Signing identity: ${DEV_ID}"

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
    -path "*Release*${APP_NAME}.app" -type d -print -quit 2>/dev/null)

if [[ -z "${BUILT_APP}" ]]; then
    echo "✗ Couldn't find the built .app under DerivedData."
    exit 1
fi

echo "▸ Staging DMG contents…"
mkdir -p "${BUILD_DIR}"
rm -rf "${DMG_DIR}" "${DMG_PATH}"
mkdir -p "${DMG_DIR}"
ditto "${BUILT_APP}" "${DMG_DIR}/${APP_NAME}.app"
STAGE_APP="${DMG_DIR}/${APP_NAME}.app"

echo "▸ Signing (Developer ID + hardened runtime)…"
codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${DEV_ID}" \
    "${STAGE_APP}"
codesign --verify --strict --verbose=2 "${STAGE_APP}"

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
