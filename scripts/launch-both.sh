#!/usr/bin/env bash

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

  log "Launch failed for $device_name; launch manually if needed."
  return 1
}

main() {
  log "Launching GolfSwingRTC on red ($RED_UDID) and orange ($ORANGE_UDID)"

  local -a pids=()

  launch_app "red" "$RED_UDID" "sender" &
  pids+=($!)

  launch_app "orange" "$ORANGE_UDID" "receiver" &
  pids+=($!)

  local status=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      status=1
    fi
  done

  if [[ $status -eq 0 ]]; then
    log "Launch commands issued successfully."
  else
    log "One or more launch commands failed."
  fi

  return $status
}

main "$@"
