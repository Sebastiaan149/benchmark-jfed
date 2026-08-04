#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}"
CONCURRENCY="${CONCURRENCY:-1 2 4 8 16}"
ITERATIONS="${ITERATIONS:-$(node_json 'c.defaultIterations')}"
QUERY_LIMIT="${QUERY_LIMIT:-0}"
SERVER_STARTUP_SECONDS="${SERVER_STARTUP_SECONDS:-8}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-$(node_json 'c.resources.sampleIntervalMs || 1000')}"

cache_modes_for_framework() {
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log((c.frameworks[process.argv[2]].cacheModes || ['cold']).join(' '))" "$CONFIG_FILE" "$1"
}

stop_local_server() {
  local pid="$1"
  kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
  local deadline="$((SECONDS + 30))"
  while kill -0 -- "-$pid" >/dev/null 2>&1 && [[ "$SECONDS" -lt "$deadline" ]]; do
    sleep 1
  done
  if kill -0 -- "-$pid" >/dev/null 2>&1; then
    kill -KILL -- "-$pid" >/dev/null 2>&1 || kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  wait "$pid" >/dev/null 2>&1 || true
  if kill -0 -- "-$pid" >/dev/null 2>&1; then
    echo "Local server process group $pid is still running; refusing to continue." >&2
    return 1
  fi
}

wait_for_server() {
  local framework="$1"
  local port="$2"
  local url
  url="$(framework_source "$framework" "$port")"
  url="${url#*@}"
  for _ in $(seq 1 "$SERVER_STARTUP_SECONDS"); do
    if curl -fsS -I "$url" >/dev/null 2>&1 || curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "Server did not answer at $url after ${SERVER_STARTUP_SECONDS}s." >&2
  return 1
}

run_one_server_group() {
  local framework="$1"
  local size="$2"
  local port
  port="$(framework_port "$framework")"
  local server_log="$LOG_ROOT/server-$size-$framework.log"

  setsid "$SCRIPT_DIR/../server/start-server.sh" "$framework" "$size" > "$server_log" 2>&1 &
  local server_pid=$!
  trap 'stop_local_server "$server_pid"' RETURN
  wait_for_server "$framework" "$port"

  for cache in $(cache_modes_for_framework "$framework"); do
    for c in $CONCURRENCY; do
      echo "==> Running $framework size=$size cache=$cache concurrency=$c iterations=$ITERATIONS"
      local run_root="$RESULTS_ROOT/$size/$framework/$cache/c$c"
      mkdir -p "$run_root"
      local server_resource_file="$run_root/server-resources.csv"
      node "$SCRIPT_DIR/../metrics/monitor-process-tree.js" \
        --pid "$server_pid" \
        --out "$server_resource_file" \
        --interval "$SAMPLE_INTERVAL_MS" &
      local monitor_pid=$!
      set +e
      node "$SCRIPT_DIR/../benchmark/run-benchmark.js" \
        --framework "$framework" \
        --size "$size" \
        --cache "$cache" \
        --concurrency "$c" \
        --iterations "$ITERATIONS" \
        --query-limit "$QUERY_LIMIT" \
        --sample-interval-ms "$SAMPLE_INTERVAL_MS" \
        --server-resource-file "$server_resource_file"
      local benchmark_status=$?
      set -e
      kill "$monitor_pid" >/dev/null 2>&1 || true
      wait "$monitor_pid" >/dev/null 2>&1 || true
      if [[ "$benchmark_status" -ne 0 ]]; then
        return "$benchmark_status"
      fi
    done
  done

  stop_local_server "$server_pid"
  trap - RETURN
}

for size in $SIZES; do
  for framework in $FRAMEWORKS; do
    run_one_server_group "$framework" "$size"
  done
done

node "$SCRIPT_DIR/../analysis/aggregate-results.js"
