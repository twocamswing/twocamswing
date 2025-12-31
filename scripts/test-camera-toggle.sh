#!/usr/bin/env bash
#
# test-camera-toggle.sh - Test front/back camera toggle on sender
#
# This script:
# 1. Builds and installs the app on both devices
# 2. Launches receiver on orange device
# 3. Runs UI test on red (sender) that waits 15s then toggles camera
#

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_BUNDLE_ID="com.twocamswing.app"

DEFAULT_RED_UDID=00008030-0018494221DB802E
DEFAULT_ORANGE_UDID=00008030-000C556E2600202E

RED_UDID=${RED_UDID:-${SENDER_UDID:-$DEFAULT_RED_UDID}}
ORANGE_UDID=${ORANGE_UDID:-${RECEIVER_UDID:-$DEFAULT_ORANGE_UDID}}

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

cleanup() {
  log "Cleaning up..."
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

# Build first
log "Building app..."
cd "$REPO_ROOT"
xcodebuild -workspace GolfSwingRTC.xcworkspace \
  -scheme GolfSwingRTC \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$REPO_ROOT/DerivedData" \
  build 2>&1 | tail -5

# Install on both devices
log "Installing on sender (red)..."
ios-deploy --id "$RED_UDID" --bundle "$REPO_ROOT/DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app" --no-wifi 2>&1 | grep -E "Install|%\]|Complete" || true

log "Installing on receiver (orange)..."
ios-deploy --id "$ORANGE_UDID" --bundle "$REPO_ROOT/DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app" --no-wifi 2>&1 | grep -E "Install|%\]|Complete" || true

# Launch receiver on orange first
log "Launching receiver on orange..."
xcrun devicectl device process launch --terminate-existing --device "$ORANGE_UDID" "$APP_BUNDLE_ID" || {
  log "Failed to launch on orange"
  exit 1
}

# Wait for receiver to start
sleep 3

# Tap receiver button on orange using UI automation
log "Starting receiver mode on orange via UI test..."
xcodebuild test \
  -workspace "$REPO_ROOT/GolfSwingRTC.xcworkspace" \
  -scheme GolfSwingRTC \
  -destination "platform=iOS,id=$ORANGE_UDID" \
  -only-testing:GolfSwingRTCUITests/GolfSwingRTCUITests/testStartReceiverFlow \
  2>&1 | grep -E "Test Case|passed|failed" &

ORANGE_PID=$!

# Give receiver a moment to start
sleep 5

# Now run sender camera toggle test on red
log "Running camera toggle test on red (sender)..."
log "Will wait 15 seconds then toggle to front camera..."
xcodebuild test \
  -workspace "$REPO_ROOT/GolfSwingRTC.xcworkspace" \
  -scheme GolfSwingRTC \
  -destination "platform=iOS,id=$RED_UDID" \
  -only-testing:GolfSwingRTCUITests/GolfSwingRTCUITests/testSenderCameraToggle \
  2>&1 | tee /tmp/camera-toggle-test.log | grep -E "Test Case|passed|failed|Waiting|Switched"

# Wait for orange test to finish
wait $ORANGE_PID 2>/dev/null || true

log "Test complete. Full log at /tmp/camera-toggle-test.log"
