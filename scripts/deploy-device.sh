#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DERIVED_DATA="$REPO_ROOT/DerivedData"
APP_NAME="GolfSwingRTC"
SCHEME="$APP_NAME"
WORKSPACE="$REPO_ROOT/$APP_NAME.xcworkspace"
BUILD_CONFIGURATION="Debug"
APP_PATH="$DERIVED_DATA/Build/Products/${BUILD_CONFIGURATION}-iphoneos/${APP_NAME}.app"

DEFAULT_RED_UDID=00008030-0018494221DB802E
DEFAULT_ORANGE_UDID=00008030-000C556E2600202E

usage() {
  cat <<USAGE
USAGE: $(basename "$0") [--red | --orange | --udid <device-udid>]

Builds the latest GolfSwingRTC app and installs it on the specified device without launching.

  --red       install on the default Red sender device ($DEFAULT_RED_UDID)
  --orange    install on the default Orange receiver device ($DEFAULT_ORANGE_UDID)
  --udid ID   install on the device with the given UDID

If no option is provided, the default is --orange.
USAGE
}

DEVICE_UDID="$DEFAULT_ORANGE_UDID"
TARGET_NAME="orange"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --red)
      DEVICE_UDID="$DEFAULT_RED_UDID"
      TARGET_NAME="red"
      shift
      ;;
    --orange)
      DEVICE_UDID="$DEFAULT_ORANGE_UDID"
      TARGET_NAME="orange"
      shift
      ;;
    --udid)
      [[ $# -ge 2 ]] || { echo "--udid requires a value" >&2; usage; exit 1; }
      DEVICE_UDID="$2"
      TARGET_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  done

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

disable_pretty_build_output() {
  if ! command -v xcbeautify >/dev/null 2>&1; then
    log "xcbeautify not found; install via 'brew install xcbeautify' for pretty build logs."
    export XCBEAUTIFY_DISABLED=1
  fi
}

run_xcodebuild() {
  log "Building $APP_NAME for generic iOS device..."
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    clean build | { [ -z "${XCBEAUTIFY_DISABLED:-}" ] && xcbeautify || cat; }
  log "Build finished: $APP_PATH"
}

install_app() {
  log "Installing on $TARGET_NAME ($DEVICE_UDID)..."
  if ! xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIGURATION" \
    -destination "id=$DEVICE_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    install >/tmp/${TARGET_NAME}-install.log 2>&1; then
      log "Install failed on $TARGET_NAME. See /tmp/${TARGET_NAME}-install.log"
      cat /tmp/${TARGET_NAME}-install.log
      return 1
  fi
  log "Install complete on $TARGET_NAME"
}

main() {
  disable_pretty_build_output
  run_xcodebuild
  install_app
  log "Deployment complete for $TARGET_NAME (app installed only; not launched)."
}

main "$@"
