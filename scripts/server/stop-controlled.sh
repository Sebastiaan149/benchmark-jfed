#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

PID_FILE="${PID_FILE:-$TMP_ROOT/jfed-server.pid}"
SERVER_CGROUP_ROOT="${SERVER_CGROUP_ROOT:-/sys/fs/cgroup/watdiv-server}"
SERVER_STOP_TIMEOUT_SECONDS="${SERVER_STOP_TIMEOUT_SECONDS:-30}"

cgroup_populated() {
  [[ -f "$SERVER_CGROUP_ROOT/cgroup.events" ]] && grep -q '^populated 1$' "$SERVER_CGROUP_ROOT/cgroup.events"
}

signal_cgroup() {
  local signal="$1"
  [[ -f "$SERVER_CGROUP_ROOT/cgroup.procs" ]] || return 0
  while IFS= read -r member_pid; do
    if [[ "$member_pid" =~ ^[0-9]+$ ]]; then
      sudo kill "-$signal" "$member_pid" >/dev/null 2>&1 || true
    fi
  done < "$SERVER_CGROUP_ROOT/cgroup.procs"
}

wait_until_stopped() {
  local timeout="$1"
  local deadline="$((SECONDS + timeout))"
  while cgroup_populated && [[ "$SECONDS" -lt "$deadline" ]]; do
    sleep 1
  done
  ! cgroup_populated
}

signal_cgroup TERM

if ! wait_until_stopped "$SERVER_STOP_TIMEOUT_SECONDS"; then
  echo "Server did not stop after ${SERVER_STOP_TIMEOUT_SECONDS}s; forcing its complete cgroup to exit." >&2
  if [[ -f "$SERVER_CGROUP_ROOT/cgroup.kill" ]]; then
    echo 1 | sudo tee "$SERVER_CGROUP_ROOT/cgroup.kill" >/dev/null
  else
    signal_cgroup KILL
  fi
fi

if ! wait_until_stopped 10; then
  echo "Server cgroup is still populated; refusing to continue to another server." >&2
  exit 1
fi

rm -f "$PID_FILE"
echo "The controlled server is completely stopped."
