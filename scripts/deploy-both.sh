#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DERIVED_DATA="$REPO_ROOT/DerivedData"
APP_NAME="GolfSwingRTC"
SCHEME="$APP_NAME"
WORKSPACE="$REPO_ROOT/$APP_NAME.xcworkspace"
BUILD_CONFIGURATION="Debug"
APP_BUNDLE_ID="com.mycompany.GolfSwingRTC"
APP_PATH="$DERIVED_DATA/Build/Products/${BUILD_CONFIGURATION}-iphoneos/${APP_NAME}.app"

DEFAULT_RED_UDID=00008030-0018494221DB802E
DEFAULT_ORANGE_UDID=00008030-000C556E2600202E

RED_UDID=${RED_UDID:-${SENDER_UDID:-$DEFAULT_RED_UDID}}
ORANGE_UDID=${ORANGE_UDID:-${RECEIVER_UDID:-$DEFAULT_ORANGE_UDID}}

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[$(timestamp)] $*"
}

run_xcodebuild() {
  log "Building $APP_NAME for generic iOS device..."
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    clean build | xcbeautify || { log "Build failed"; exit 1; }
  log "Build finished: $APP_PATH"
}

install_app() {
  local device_name=$1
  local udid=$2

  log "Installing on $device_name ($udid)..."
  if ! xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIGURATION" \
    -destination "id=$udid" \
    -derivedDataPath "$DERIVED_DATA" \
    install >/tmp/${device_name}-install.log 2>&1; then
      log "Install failed on $device_name. See /tmp/${device_name}-install.log"
      cat /tmp/${device_name}-install.log
      return 1
  fi
  log "Install complete on $device_name"
}

launch_app() {
  local device_name=$1
  local udid=$2
  local auto_role=${3:-}

  log "Launching on $device_name${auto_role:+ (AUTO_ROLE=$auto_role)}"

  if [[ -n "$auto_role" ]]; then
    DEVICECTL_CHILD_AUTO_ROLE="$auto_role" \
      xcrun devicectl device process launch --terminate-existing --device "$udid" "$APP_BUNDLE_ID" && {
        log "Launch command issued for $device_name with AUTO_ROLE=$auto_role"
        return 0
      }
  else
    if xcrun devicectl device process launch --terminate-existing --device "$udid" "$APP_BUNDLE_ID"; then
      log "Launch command issued for $device_name"
      return 0
    fi
  fi

  log "Launch failed for $device_name via devicectl; device may not support CoreDevice. Launch manually."
  return 1
}

if ! command -v xcbeautify >/dev/null 2>&1; then
  log "xcbeautify not found; install via 'brew install xcbeautify' for pretty build logs."
  export XCBEAUTIFY_DISABLED=1
fi

if [[ ${XCBEAUTIFY_DISABLED:-0} -eq 1 ]]; then
  run_xcodebuild() {
    log "Building $APP_NAME for generic iOS device..."
    xcodebuild \
      -workspace "$WORKSPACE" \
      -scheme "$SCHEME" \
      -configuration "$BUILD_CONFIGURATION" \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$DERIVED_DATA" \
      clean build
    log "Build finished: $APP_PATH"
  }
fi

run_xcodebuild

install_app "red"    "$RED_UDID" || exit 1
install_app "orange" "$ORANGE_UDID" || exit 1

launch_app "red"    "$RED_UDID"    "sender"
launch_app "orange" "$ORANGE_UDID" "receiver"

log "Deployment complete for red and orange."
