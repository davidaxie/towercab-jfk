#!/usr/bin/env bash
# =============================================================================
# run-on-device.sh — build TowerCab: Slammed and install it on a connected
# iPad so you can run the put-down test on real hardware (and check 60 fps on
# the floor device). The simulator cannot validate frame rate, touch feel, or
# spatial audio on headphones — those are what this is for.
#
# Prereqs (one-time):
#   • A free Apple ID added to Xcode (Settings ▸ Accounts). Personal-team
#     signing is enough for a 7-day on-device build.
#   • The iPad plugged in (or paired over the network) and "trusted".
#   • Find your team id:  xcrun xcodebuild -showBuildSettings | grep DEVELOPMENT_TEAM
#     or Xcode ▸ Settings ▸ Accounts ▸ (your team) — the 10-char ID.
#
# Usage:
#   scripts/run-on-device.sh <TEAM_ID>
#   scripts/run-on-device.sh <TEAM_ID> --launch
# =============================================================================
set -euo pipefail

TEAM_ID="${1:-}"
LAUNCH="${2:-}"
if [[ -z "$TEAM_ID" ]]; then
  echo "usage: $0 <TEAM_ID> [--launch]"
  echo "  (your 10-character Apple Developer team id; see the header of this script)"
  exit 1
fi

cd "$(dirname "$0")/.."
DEV="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$DEV"
BUNDLE_ID="com.davidxie.towercab-slammed"
DD="build/device"

echo "▸ Regenerating project…"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

echo "▸ Finding a connected device…"
DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null \
  | awk '/connected/ && /iPad|iPhone/ {print $(NF-1); exit}')"
if [[ -z "${DEVICE_ID:-}" ]]; then
  echo "  No connected device found. Plug in the iPad, trust this Mac, and retry."
  echo "  (list devices with:  xcrun devicectl list devices )"
  exit 1
fi
echo "  device: $DEVICE_ID"

echo "▸ Building for device with team $TEAM_ID (automatic signing)…"
xcodebuild -project TowerCabSlammed.xcodeproj -scheme TowerCabSlammed \
  -destination "generic/platform=iOS" -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build | tail -3

APP="$(/usr/bin/find "$DD/Build/Products" -maxdepth 2 -name 'TowerCabSlammed.app' | head -1)"
echo "▸ Installing $APP …"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

if [[ "$LAUNCH" == "--launch" ]]; then
  echo "▸ Launching…"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
fi
echo "✓ Installed. Hold the iPad in landscape, put on headphones, and play."
