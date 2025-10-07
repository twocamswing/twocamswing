#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

timestamp() {
  date +"%Y-%m-%d_%H-%M-%S"
}

run_stream() {
  local device_name=$1
  local udid=$2
  local outfile=$3

  if [[ -z "$udid" ]]; then
    echo "No UDID provided for $device_name; set ${device_name^^}_UDID." >&2
    return 1
  fi

  local predicate='process == "GolfSwingRTC"'
  echo "[$(timestamp)] Starting log stream for $device_name ($udid) -> $outfile"
  echo "Press Ctrl+C to stop."

  # shellcheck disable=SC2086
  xcrun log stream --device "$udid" --style compact --predicate "$predicate" \
    2>&1 | tee "$outfile" | sed "s/^/[$device_name] /"
}

RED_UDID=${RED_UDID:-00008030-0018494221DB802E}
ORANGE_UDID=${ORANGE_UDID:-00008030-000C556E2600202E}

start_red() {
  local outfile="$LOG_DIR/red.log"
  run_stream "red" "$RED_UDID" "$outfile"
}

start_orange() {
  local outfile="$LOG_DIR/orange.log"
  run_stream "orange" "$ORANGE_UDID" "$outfile"
}

start_red &
RED_PID=$!
start_orange &
ORANGE_PID=$!

trap 'echo "Stopping log streams"; kill $RED_PID $ORANGE_PID 2>/dev/null || true' INT TERM
wait $RED_PID $ORANGE_PID
