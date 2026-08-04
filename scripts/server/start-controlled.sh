#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

FRAMEWORK="${FRAMEWORK:-smartkg}"
SIZE="${SIZE:-100m}"
LOG_DIR="${LOG_DIR:-$LOG_ROOT/jfed}"
PID_FILE="${PID_FILE:-$TMP_ROOT/jfed-server.pid}"
SERVER_CGROUP_ROOT="${SERVER_CGROUP_ROOT:-/sys/fs/cgroup/watdiv-server}"

require_command setsid
mkdir -p "$LOG_DIR" "$(dirname "$PID_FILE")"
sudo mkdir -p "$SERVER_CGROUP_ROOT"
if [[ ! -f "$SERVER_CGROUP_ROOT/cgroup.procs" || ! -f "$SERVER_CGROUP_ROOT/cgroup.events" ]]; then
  echo "A cgroup v2 hierarchy is required at $SERVER_CGROUP_ROOT." >&2
  exit 1
fi

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE")"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "A controlled server is still running as pid $old_pid; refusing to start another." >&2
    exit 1
  fi
  rm -f "$PID_FILE"
fi

if [[ -s "$SERVER_CGROUP_ROOT/cgroup.procs" ]]; then
  echo "The previous server cgroup is not empty; run stop-controlled.sh before starting another server." >&2
  exit 1
fi

# Keep the cgroup for complete process-tree shutdown and monitoring, but do not
# impose CPU or RAM limits. This also clears limits left by an older deployment.
if [[ -f "$SERVER_CGROUP_ROOT/cpu.max" ]]; then
  echo max | sudo tee "$SERVER_CGROUP_ROOT/cpu.max" >/dev/null
fi
if [[ -f "$SERVER_CGROUP_ROOT/memory.max" ]]; then
  echo max | sudo tee "$SERVER_CGROUP_ROOT/memory.max" >/dev/null
fi

(
  # Capture the long-lived launcher shell before starting the pipeline. Using
  # BASHPID directly inside the pipeline identifies its short-lived echo
  # subprocess, which may exit before tee writes the PID to cgroup.procs.
  launcher_pid="$BASHPID"
  printf '%s\n' "$launcher_pid" | sudo tee "$SERVER_CGROUP_ROOT/cgroup.procs" >/dev/null
  exec setsid "$SCRIPT_DIR/start-server.sh" "$FRAMEWORK" "$SIZE"
) > "$LOG_DIR/server-$SIZE-$FRAMEWORK.log" 2>&1 &

pid=$!
echo "$pid" > "$PID_FILE"
echo "Started $FRAMEWORK $SIZE as pid $pid. Log: $LOG_DIR/server-$SIZE-$FRAMEWORK.log"
