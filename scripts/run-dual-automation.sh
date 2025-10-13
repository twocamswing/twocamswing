#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE="$REPO_ROOT/GolfSwingRTC.xcworkspace"
SCHEME="GolfSwingRTC"
DERIVED_DATA="$REPO_ROOT/DerivedData"
RESULTS_DIR="$REPO_ROOT/TestResults"

DEFAULT_RED_UDID=00008030-0018494221DB802E
DEFAULT_ORANGE_UDID=00008030-000C556E2600202E

RED_UDID=${RED_UDID:-${SENDER_UDID:-$DEFAULT_RED_UDID}}
ORANGE_UDID=${ORANGE_UDID:-${RECEIVER_UDID:-$DEFAULT_ORANGE_UDID}}

mkdir -p "$RESULTS_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

build_app() {
  log "Building $SCHEME (no tests)"
  xcodebuild \
    build \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA"
}

run_sender_test() {
  local bundle="$RESULTS_DIR/sender-$(date '+%Y%m%d-%H%M%S').xcresult"
  xcodebuild \
    test-without-building \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "id=$RED_UDID" \
    -only-testing:GolfSwingRTCUITests/GolfSwingRTCUITests/testStartSenderFlow \
    -resultBundlePath "$bundle" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration
}

run_receiver_test() {
  local bundle="$RESULTS_DIR/receiver-$(date '+%Y%m%d-%H%M%S').xcresult"
  xcodebuild \
    test-without-building \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -destination "id=$ORANGE_UDID" \
    -only-testing:GolfSwingRTCUITests/GolfSwingRTCUITests/testStartReceiverFlow \
    -resultBundlePath "$bundle" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration
}

main() {
  if [[ ${SKIP_BUILD:-0} -ne 1 ]]; then
    build_app
  else
    log "Skipping build step (SKIP_BUILD=${SKIP_BUILD})"
  fi

  log "Starting sender automation on $RED_UDID and receiver automation on $ORANGE_UDID"

  run_sender_test &
  SENDER_PID=$!
  run_receiver_test &
  RECEIVER_PID=$!

  trap 'log "Cancelling automation"; kill "$SENDER_PID" "$RECEIVER_PID" 2>/dev/null || true' INT TERM

  local status=0
  if ! wait "$SENDER_PID"; then
    log "Sender automation failed"
    status=1
  fi
  if ! wait "$RECEIVER_PID"; then
    log "Receiver automation failed"
    status=1
  fi

  if [[ $status -eq 0 ]]; then
    log "Dual automation completed successfully"
  else
    log "Dual automation completed with errors"
  fi

  return $status
}

main "$@"
