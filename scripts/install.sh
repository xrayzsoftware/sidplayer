#!/usr/bin/env bash
# Build a fresh Release of SID Player and install it to /Applications.
# Run from the repo root: ./scripts/install.sh

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SIDPlayer.xcodeproj"
SCHEME="SIDPlayer"
INSTALL_PATH="/Applications/SID Player.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# Regenerate the Xcode project from project.yml in case it drifted.
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

# Locate the built .app under DerivedData.
BUILT_APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*Release*SID Player.app" -type d 2>/dev/null \
    | head -1)

if [[ -z "${BUILT_APP}" ]]; then
    echo "✗ Couldn't find the built .app under DerivedData."
    exit 1
fi

echo "▸ Installing to ${INSTALL_PATH}…"
pkill -f "SID Player" 2>/dev/null || true
sleep 1
rm -rf "${INSTALL_PATH}"
ditto "${BUILT_APP}" "${INSTALL_PATH}"
"$LSREG" -f "${INSTALL_PATH}" 2>/dev/null || true
killall Dock 2>/dev/null || true

echo "✓ Installed: ${INSTALL_PATH}"
echo "  (launch via Spotlight / Launchpad, or: open \"${INSTALL_PATH}\")"
