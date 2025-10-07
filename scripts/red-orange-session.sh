#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG_DIR="$REPO_ROOT/logs"
DEPLOY_SCRIPT="$REPO_ROOT/scripts/deploy-both.sh"

DEFAULT_RED_UDID=00008030-0018494221DB802E
DEFAULT_ORANGE_UDID=00008030-000C556E2600202E

RED_UDID=${RED_UDID:-${SENDER_UDID:-$DEFAULT_RED_UDID}}
ORANGE_UDID=${ORANGE_UDID:-${RECEIVER_UDID:-$DEFAULT_ORANGE_UDID}}

mkdir -p "$LOG_DIR"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

timestamp_for_file() {
  date +"%Y%m%d-%H%M%S"
}

log() {
  echo "[$(timestamp)] $*"
}

start_log_stream() {
  local device_name=$1
  local udid=$2
  local outfile="$LOG_DIR/${device_name}-$(timestamp_for_file).log"

  if ! command -v idevicesyslog >/dev/null 2>&1; then
    log "idevicesyslog not found; skipping log capture for $device_name"
    eval "${device_name^^}_LOG_FILE=\"\""
    echo ""
    return
  fi

  log "Starting log capture for $device_name ($udid) -> $outfile"

  (
    idevicesyslog -u "$udid" -p GolfSwingRTC 2>&1 \
      | tee "$outfile" | sed "s/^/[$device_name] /"
  ) &

  eval "${device_name^^}_LOG_FILE=\"$outfile\""
  echo $!
}

stop_log_stream() {
  local pid=$1
  [[ -z "$pid" ]] && return

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

cleanup_streams() {
  stop_log_stream "${RED_LOG_PID:-}"
  stop_log_stream "${ORANGE_LOG_PID:-}"
}

log "Deploying GolfSwingRTC to red ($RED_UDID) and orange ($ORANGE_UDID)"
SENDER_UDID="$RED_UDID" RECEIVER_UDID="$ORANGE_UDID" bash "$DEPLOY_SCRIPT"

RED_LOG_PID=$(start_log_stream "red" "$RED_UDID")
ORANGE_LOG_PID=$(start_log_stream "orange" "$ORANGE_UDID")

trap cleanup_streams INT TERM EXIT

if [[ -n "$RED_LOG_PID" || -n "$ORANGE_LOG_PID" ]]; then
  log "Capturing device logs for 5 seconds..."
  sleep 5
  log "Stopping log capture"
  cleanup_streams
else
  log "No log capture processes started."
fi

if [[ -n "${RED_LOG_FILE:-}" ]]; then
  log "red logs saved to ${RED_LOG_FILE}"
fi

if [[ -n "${ORANGE_LOG_FILE:-}" ]]; then
  log "orange logs saved to ${ORANGE_LOG_FILE}"
fi
