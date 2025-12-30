#!/usr/bin/env bash
#
# run-capture-test.sh - End-to-end test for capture and bulk delete
#
# This script:
# 1. Launches sender on red device
# 2. Waits for sender to be ready
# 3. Runs UI tests on orange device (receiver) that:
#    - Starts receiver mode
#    - Captures multiple swings
#    - Tests bulk delete
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
  # Kill any background processes
  jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT

# Build first
log "Building app for testing..."
cd "$REPO_ROOT"
xcodebuild -workspace GolfSwingRTC.xcworkspace \
  -scheme GolfSwingRTC \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$REPO_ROOT/DerivedData" \
  build 2>&1 | tail -5

# Install on both devices
log "Installing on sender (red)..."
ios-deploy --id "$RED_UDID" --bundle "$REPO_ROOT/DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app" --no-wifi 2>&1 | grep -E "Install|%\]" || true

log "Installing on receiver (orange)..."
ios-deploy --id "$ORANGE_UDID" --bundle "$REPO_ROOT/DerivedData/Build/Products/Debug-iphoneos/GolfSwingRTC.app" --no-wifi 2>&1 | grep -E "Install|%\]" || true

# Launch sender on red
log "Launching sender on red..."
DEVICECTL_CHILD_AUTO_ROLE=sender xcrun devicectl device process launch --terminate-existing --device "$RED_UDID" "$APP_BUNDLE_ID" || {
  log "Failed to launch sender"
  exit 1
}

# Wait for sender to initialize
log "Waiting for sender to initialize..."
sleep 5

# Now run UI tests on orange (receiver)
log "Running capture UI tests on orange..."
xcodebuild test \
  -workspace "$REPO_ROOT/GolfSwingRTC.xcworkspace" \
  -scheme GolfSwingRTC \
  -destination "platform=iOS,id=$ORANGE_UDID" \
  -only-testing:GolfSwingRTCUITests/GolfSwingRTCUITests/testCaptureAndBulkDelete \
  2>&1 | tee /tmp/capture-test.log | grep -E "Test Case|passed|failed|error:"

log "Test complete. Full log at /tmp/capture-test.log"
