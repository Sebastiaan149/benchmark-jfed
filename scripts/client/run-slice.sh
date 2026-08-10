#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

FRAMEWORK="${FRAMEWORK:-smartkg}"
SIZE="${SIZE:-100m}"
CACHE="${CACHE:-cold}"
LOCAL_CLIENTS="${LOCAL_CLIENTS:-1}"
TOTAL_CONCURRENCY="${TOTAL_CONCURRENCY:-$LOCAL_CLIENTS}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
RUN_LABEL="${RUN_LABEL:-}"
SERVER_IP="${SERVER_IP:?Missing benchmark server LAN address}"
PORT="${PORT:-}"
QUERY_LIMIT="${QUERY_LIMIT:-0}"
ITERATIONS="${ITERATIONS:-1}"
NETNS_PREFIX="${NETNS_PREFIX:-}"
CLIENT_CGROUP_ROOT="${CLIENT_CGROUP_ROOT:-/sys/fs/cgroup/watdiv-clients}"
CLIENT_CPU_MAX="${CLIENT_CPU_MAX:-}"
CLIENT_MEMORY_MAX="${CLIENT_MEMORY_MAX:-}"
SERVER_RESOURCE_FILE="${SERVER_RESOURCE_FILE:-}"
RETAIN_QUERY_OUTPUTS="${RETAIN_QUERY_OUTPUTS:-0}"
KEEP_CLIENT_CACHES="${KEEP_CLIENT_CACHES:-0}"
WORKLOAD_PHASE="${WORKLOAD_PHASE:-both}"
QUERY_SELECTION="${QUERY_SELECTION:-five}"
CLIENT_NODE_OPTIONS="${CLIENT_NODE_OPTIONS:-}"
RESUME="${RESUME:-0}"

RUN_ROOT="$RESULTS_ROOT/$SIZE/$FRAMEWORK/$CACHE/c$TOTAL_CONCURRENCY"
if [[ -n "$RUN_LABEL" ]]; then
  RUN_ROOT="$RUN_ROOT/$RUN_LABEL"
fi

# Network namespaces require this script to run through sudo. Return the files
# produced by the privileged workload to the controller user before the
# unprivileged aggregation step reads and updates them.
restore_result_ownership() {
  if [[ "$(id -u)" -eq 0 && "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ && -e "$RUN_ROOT" ]]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$RUN_ROOT"
  fi
}
trap restore_result_ownership EXIT

if [[ -n "$NETNS_PREFIX" && "$(id -u)" -ne 0 ]]; then
  echo "NETNS_PREFIX requires root because ip netns exec needs elevated privileges. Re-run with sudo -E." >&2
  exit 1
fi

port_arg=()
if [[ -n "$PORT" ]]; then
  port_arg=(--port "$PORT")
fi

source_template="$(node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.frameworks[process.argv[2]].source)" "$CONFIG_FILE" "$FRAMEWORK")"
port_value="${PORT:-$(node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.frameworks[process.argv[2]].port)" "$CONFIG_FILE" "$FRAMEWORK")}"
source_url="${source_template//localhost/$SERVER_IP}"
source_url="${source_url//\{port\}/$port_value}"
client_mode="$(node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.frameworks[process.argv[2]].clientMode || '')" "$CONFIG_FILE" "$FRAMEWORK")"

if [[ "$client_mode" == "hdt-download" ]]; then
  mkdir -p "$RESULTS_ROOT"
  content_length() {
    local url="$1"
    local length
    length="$(curl -fsSI "$url" | awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2; exit }')"
    if [[ ! "$length" =~ ^[0-9]+$ ]]; then
      echo "No Content-Length received for $url; cannot verify client disk capacity." >&2
      exit 1
    fi
    echo "$length"
  }

  hdt_bytes="$(content_length "$source_url")"
  index_bytes="$(content_length "$source_url.index.v1-1")"
  available_bytes="$(df --output=avail -B1 "$RESULTS_ROOT" | tail -n 1 | tr -d ' ')"
  reserve_bytes="$((10 * 1024 * 1024 * 1024))"
  required_bytes="$((LOCAL_CLIENTS * (hdt_bytes + index_bytes) * 12 / 10 + reserve_bytes))"
  if (( available_bytes < required_bytes )); then
    echo "HDT dump run needs at least $required_bytes free bytes for $LOCAL_CLIENTS clients; only $available_bytes are available." >&2
    exit 1
  fi
  echo "HDT dump disk preflight passed: required=$required_bytes available=$available_bytes bytes."
fi

sudo mkdir -p "$CLIENT_CGROUP_ROOT"
if [[ ! -f "$CLIENT_CGROUP_ROOT/cpu.max" || ! -f "$CLIENT_CGROUP_ROOT/memory.max" ]]; then
  echo "cgroup v2 CPU and memory controllers are required at $CLIENT_CGROUP_ROOT." >&2
  exit 1
fi
available_controllers="$(cat "$CLIENT_CGROUP_ROOT/cgroup.controllers")"
for controller in cpu memory; do
  if [[ " $available_controllers " != *" $controller "* ]]; then
    echo "The cgroup v2 $controller controller is unavailable at $CLIENT_CGROUP_ROOT." >&2
    exit 1
  fi
done
echo '+cpu +memory' | sudo tee "$CLIENT_CGROUP_ROOT/cgroup.subtree_control" >/dev/null
sudo chown -R "$(id -u):$(id -g)" "$CLIENT_CGROUP_ROOT"

if [[ -n "$CLIENT_NODE_OPTIONS" ]]; then
  export NODE_OPTIONS="$CLIENT_NODE_OPTIONS"
fi

RESULTS_ROOT="$RESULTS_ROOT" DATA_ROOT="$DATA_ROOT" CONFIG_FILE="$CONFIG_FILE" \
node "$BENCHMARK_DIR/scripts/benchmark/run-benchmark.js" \
  --framework "$FRAMEWORK" \
  --size "$SIZE" \
  --cache "$CACHE" \
  --concurrency "$LOCAL_CLIENTS" \
  --total-concurrency "$TOTAL_CONCURRENCY" \
  --iterations "$ITERATIONS" \
  --query-limit "$QUERY_LIMIT" \
  --client-id-offset "$CLIENT_ID_OFFSET" \
  --retain-query-outputs "$RETAIN_QUERY_OUTPUTS" \
  --keep-client-caches "$KEEP_CLIENT_CACHES" \
  --workload-phase "$WORKLOAD_PHASE" \
  --resume "$RESUME" \
  --query-selection "$QUERY_SELECTION" \
  ${RUN_LABEL:+--run-label "$RUN_LABEL"} \
  --source "$source_url" \
  "${port_arg[@]}" \
  ${SERVER_RESOURCE_FILE:+--server-resource-file "$SERVER_RESOURCE_FILE"} \
  ${NETNS_PREFIX:+--netns-prefix "$NETNS_PREFIX"} \
  ${CLIENT_CPU_MAX:+--client-cpu-max "$CLIENT_CPU_MAX"} \
  ${CLIENT_MEMORY_MAX:+--client-memory-max "$CLIENT_MEMORY_MAX"} \
  ${CLIENT_CGROUP_ROOT:+--client-cgroup-root "$CLIENT_CGROUP_ROOT"}
