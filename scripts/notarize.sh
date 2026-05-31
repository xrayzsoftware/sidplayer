#!/usr/bin/env bash
# Build, Developer ID-sign, notarize, and staple a distributable .dmg.
# Run from the repo root: ./scripts/notarize.sh
# Output: build/SID Player.dmg  (signed + notarized + stapled)
#
# One-time setup (see scripts/README or the repo notes):
#   1. Create a "Developer ID Application" certificate in your keychain
#        (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application).
#   2. Store notary credentials once into a keychain profile:
#        xcrun notarytool store-credentials sidplayer-notary \
#            --apple-id "<your-apple-id>" --team-id "<TEAMID>" \
#            --password "<app-specific-password>"
#      (app-specific password: https://account.apple.com ▸ Sign-In & Security)
#
# Overridable via env:
#   DEV_ID         signing identity (default: first "Developer ID Application" in keychain)
#   NOTARY_PROFILE notarytool keychain profile name (default: sidplayer-notary)

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="SIDPlayer.xcodeproj"
SCHEME="SIDPlayer"
APP_NAME="SID Player"
ENTITLEMENTS="App/SIDPlayer.entitlements"
BUILD_DIR="build"
DMG_DIR="${BUILD_DIR}/dmg-stage"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-sidplayer-notary}"

# --- Resolve the Developer ID Application signing identity -------------------
DEV_ID="${DEV_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/')}"

if [[ -z "${DEV_ID}" ]]; then
    echo "✗ No 'Developer ID Application' identity found in your keychain."
    echo "  Create one: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application"
    echo "  Then re-run, or pass DEV_ID=\"Developer ID Application: Name (TEAMID)\"."
    exit 1
fi
echo "▸ Signing identity: ${DEV_ID}"

# --- Build Release ----------------------------------------------------------
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

BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*Release*${APP_NAME}.app" -type d 2>/dev/null | head -1)
if [[ -z "${BUILT_APP}" ]]; then
    echo "✗ Couldn't find the built .app under DerivedData."
    exit 1
fi

# --- Stage + Developer ID sign with hardened runtime ------------------------
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

# --- Build the DMG ----------------------------------------------------------
echo "▸ Creating DMG…"
ln -s /Applications "${DMG_DIR}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}" \
    > /dev/null

# --- Notarize the DMG -------------------------------------------------------
echo "▸ Submitting to Apple notary (this can take a few minutes)…"
set +e
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait | tee "${BUILD_DIR}/notary.log"
NRC=${PIPESTATUS[0]}
set -e
if [[ $NRC -ne 0 ]]; then
    echo "✗ Notarization failed. Fetching the log…"
    SUB_ID=$(grep -m1 -E '^[[:space:]]*id:' "${BUILD_DIR}/notary.log" | awk '{print $2}')
    [[ -n "${SUB_ID}" ]] && xcrun notarytool log "${SUB_ID}" --keychain-profile "${NOTARY_PROFILE}"
    echo "  (If creds are missing, run: xcrun notarytool store-credentials ${NOTARY_PROFILE} ...)"
    exit 1
fi

# --- Staple + verify --------------------------------------------------------
echo "▸ Stapling ticket…"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

rm -rf "${DMG_DIR}"

# Verify what actually matters: the DMG carries its stapled ticket, and the
# app inside passes Gatekeeper. (`spctl -t open` on a .dmg reports "Insufficient
# Context" from the CLI even when notarized — that's not a real failure, so we
# assess the app the user launches instead.)
echo "▸ Verifying…"
MP=$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1)
spctl -a -t exec -vv "${MP}/${APP_NAME}.app" || true
hdiutil detach "${MP}" >/dev/null 2>&1 || true

SIZE=$(du -h "${DMG_PATH}" | cut -f1 | xargs)
echo "✓ ${DMG_PATH} (${SIZE}) — signed, notarized, stapled."
echo "  Note: the app inside is notarized; first launch after drag-to-/Applications"
echo "  validates online. For offline first-launch, staple the .app before packaging."
