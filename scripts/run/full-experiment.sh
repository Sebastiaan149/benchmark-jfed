#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

# This script is the "one button" benchmark controller.
#
# Run it from client0. It controls the server node over
# SSH, starts one server implementation at a time, runs the selected client
# workloads against it, pulls back client and server metrics, stops the server,
# and then moves to the next framework.
#
# Fairness rule: even though this runs the whole benchmark in one command, it
# still keeps only one benchmark server alive at any point in time.

# SSH target for the bare-metal server on the experiment LAN.
SERVER_SSH="${SERVER_SSH:?Set the benchmark server SSH target}"

# Private experiment-LAN address used by Comunica clients.
SERVER_IP="${SERVER_IP:?Set the benchmark server LAN address}"

# Path layout on the remote server node. Keep these equal to the client-side
# paths if both nodes use the same cloned repository location.
REMOTE_WORKSPACE="${REMOTE_WORKSPACE:-$WORKSPACE_ROOT}"
REMOTE_BENCHMARK_DIR="${REMOTE_BENCHMARK_DIR:-$REMOTE_WORKSPACE/benchmark-jfed}"
REMOTE_CLIENT_WORKSPACE="${REMOTE_CLIENT_WORKSPACE:-$WORKSPACE_ROOT}"
REMOTE_CLIENT_BENCHMARK_DIR="${REMOTE_CLIENT_BENCHMARK_DIR:-$REMOTE_CLIENT_WORKSPACE/benchmark-jfed}"
REMOTE_RESULTS_ROOT="${REMOTE_RESULTS_ROOT:-$REMOTE_BENCHMARK_DIR/watdiv-results}"
REMOTE_CLIENT_RESULTS_ROOT="${REMOTE_CLIENT_RESULTS_ROOT:-$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results}"

# Benchmark matrix. Override these from the shell to make smoke runs or custom
# subsets.
SIZES="${SIZES:-1m 10m 50m 100m}"
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}"
CONCURRENCY="${CONCURRENCY:-1 2 4 8 16 32 64}"
ITERATIONS="${ITERATIONS:-3}"
QUERY_LIMIT="${QUERY_LIMIT:-0}"
CACHE_MODES="${CACHE_MODES:-auto}"

# Logical-client controls. These allow one physical client node to run many
# isolated logical clients, or multiple physical client nodes to split the same
# global client-id range.
CLIENT_NODE_CAPACITIES="${CLIENT_NODE_CAPACITIES:?Set the capacities for all physical client nodes}"
MAX_CLIENTS_PER_NODE="${MAX_CLIENTS_PER_NODE:?Set the physical-node client limit}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
NETNS_PREFIX="${NETNS_PREFIX:-bench-c}"
CLIENT_CPU_MAX="${CLIENT_CPU_MAX:-}"
CLIENT_MEMORY_MAX="${CLIENT_MEMORY_MAX:-}"
CLIENT_CGROUP_ROOT="${CLIENT_CGROUP_ROOT:-/sys/fs/cgroup/watdiv-clients}"
CLIENT_SSHS="${CLIENT_SSHS:-}"
ENABLE_CLIENT_NETNS_MONITOR="${ENABLE_CLIENT_NETNS_MONITOR:-1}"
RETAIN_QUERY_OUTPUTS="${RETAIN_QUERY_OUTPUTS:-0}"
KEEP_CLIENT_CACHES="${KEEP_CLIENT_CACHES:-0}"

SERVER_STARTUP_SECONDS="${SERVER_STARTUP_SECONDS:-60}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1000}"

# If set to 1, restart the server for every framework/size/cache/concurrency
# run. This is slower, but it avoids cache and JVM/Node warm-state differences
# between concurrency levels.
RESTART_SERVER_PER_RUN="${RESTART_SERVER_PER_RUN:-1}"

# Store server-side monitoring files under a timestamped run id, then copy them
# back to the client node after each run.
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
LOCAL_SERVER_METRICS_ROOT="$RESULTS_ROOT/server-metrics/$RUN_ID"
REMOTE_SERVER_METRICS_ROOT="$REMOTE_RESULTS_ROOT/server-metrics/$RUN_ID"
mkdir -p "$LOCAL_SERVER_METRICS_ROOT"

CLIENT_NODES=()
if [[ -n "$CLIENT_SSHS" ]]; then
  read -r -a CLIENT_NODES <<< "$CLIENT_SSHS"
fi
read -r -a CLIENT_CAPACITIES <<< "$CLIENT_NODE_CAPACITIES"

PHYSICAL_CLIENT_COUNT="$((${#CLIENT_NODES[@]} + 1))"
if (( ${#CLIENT_CAPACITIES[@]} != PHYSICAL_CLIENT_COUNT )); then
  echo "CLIENT_NODE_CAPACITIES has ${#CLIENT_CAPACITIES[@]} entries, but the cluster has $PHYSICAL_CLIENT_COUNT physical client nodes." >&2
  exit 1
fi
TOTAL_CLIENT_CAPACITY=0
for capacity in "${CLIENT_CAPACITIES[@]}"; do
  TOTAL_CLIENT_CAPACITY="$((TOTAL_CLIENT_CAPACITY + capacity))"
done

ACTIVE_CLIENT_NODES=()
ACTIVE_RUN_LABELS=()
ACTIVE_LOCAL_CLIENTS=()
ACTIVE_CLIENT_OFFSETS=()

# Run a command on the server node. BatchMode makes SSH fail immediately if keys
# are not configured, instead of prompting in the middle of a long benchmark.
remote() {
  ssh -o BatchMode=yes "$SERVER_SSH" "$@"
}

remote_client() {
  local client="$1"
  shift
  ssh -o BatchMode=yes "$client" "$@"
}

use_remote_clients() {
  [[ "${#CLIENT_NODES[@]}" -gt 0 ]]
}

# Build a safely quoted environment prefix for remote server commands.
remote_export_prefix() {
  printf 'WORKSPACE_ROOT=%q BENCHMARK_DIR=%q DATA_ROOT=%q RESULTS_ROOT=%q CONFIG_FILE=%q SAMPLE_INTERVAL_MS=%q ' \
    "$REMOTE_WORKSPACE" "$REMOTE_BENCHMARK_DIR" "$REMOTE_BENCHMARK_DIR/data" "$REMOTE_RESULTS_ROOT" "$REMOTE_BENCHMARK_DIR/config/frameworks.json" "$SAMPLE_INTERVAL_MS"
}

remote_client_export_prefix() {
  printf 'WORKSPACE_ROOT=%q BENCHMARK_DIR=%q DATA_ROOT=%q RESULTS_ROOT=%q CONFIG_FILE=%q SERVER_IP=%q NETNS_PREFIX=%q CLIENT_CPU_MAX=%q CLIENT_MEMORY_MAX=%q CLIENT_CGROUP_ROOT=%q RETAIN_QUERY_OUTPUTS=%q KEEP_CLIENT_CACHES=%q ' \
    "$REMOTE_CLIENT_WORKSPACE" "$REMOTE_CLIENT_BENCHMARK_DIR" "$REMOTE_CLIENT_BENCHMARK_DIR/data" "$REMOTE_CLIENT_RESULTS_ROOT" "$REMOTE_CLIENT_BENCHMARK_DIR/config/frameworks.json" "$SERVER_IP" "$NETNS_PREFIX" "$CLIENT_CPU_MAX" "$CLIENT_MEMORY_MAX" "$CLIENT_CGROUP_ROOT" "$RETAIN_QUERY_OUTPUTS" "$KEEP_CLIENT_CACHES"
}

# Read the configured HTTP port for a framework from the benchmark JSON config.
framework_port() {
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.frameworks[process.argv[2]].port)" \
    "$CONFIG_FILE" "$1"
}

# Convert the framework source string into a plain HTTP URL that curl can probe.
# Some Comunica sources have a prefix such as "wisekg@http://..."; curl only
# wants the URL part.
framework_source_url() {
  local framework="$1"
  local port="$2"
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); const s=c.frameworks[process.argv[2]].source.replaceAll('localhost', process.argv[3]).replaceAll('{port}', process.argv[4]); console.log(s.includes('@') ? s.split('@').pop() : s)" \
    "$CONFIG_FILE" "$framework" "$SERVER_IP" "$port"
}

# Cache modes are framework-specific by default. For example, SmartKG-like
# systems may have cold and warm runs, while simple endpoints usually only use
# cold runs.
cache_modes_for_framework() {
  if [[ "$CACHE_MODES" != "auto" ]]; then
    echo "$CACHE_MODES"
  else
    node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log((c.frameworks[process.argv[2]].cacheModes || ['cold']).join(' '))" \
      "$CONFIG_FILE" "$1"
  fi
}

# Wait until the selected server endpoint is reachable before starting clients.
# This avoids measuring server boot time as query latency.
wait_for_server() {
  local framework="$1"
  local size="$2"
  local port
  local url
  local attempt
  port="$(framework_port "$framework")"
  url="$(framework_source_url "$framework" "$port")"
  for attempt in $(seq 1 "$SERVER_STARTUP_SECONDS"); do
    if curl -fsS -I "$url" >/dev/null 2>&1 || curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt % 5 == 0 )) && ! remote "pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server.pid' 2>/dev/null || true); [[ \"\$pid\" =~ ^[0-9]+\$ ]] && kill -0 \"\$pid\" 2>/dev/null"; then
      echo "Server process exited before answering at $url." >&2
      show_server_diagnostics "$framework" "$size"
      return 1
    fi
    sleep 1
  done
  echo "Server did not answer at $url after ${SERVER_STARTUP_SECONDS}s." >&2
  show_server_diagnostics "$framework" "$size"
  return 1
}

# Print enough remote state to diagnose startup failures directly from the
# controller. Logs remain available after the cleanup trap stops the server.
show_server_diagnostics() {
  local framework="$1"
  local size="$2"
  local log_file="$REMOTE_BENCHMARK_DIR/logs/jfed/server-$size-$framework.log"
  remote "echo '--- remote server process ---'; pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server.pid' 2>/dev/null || true); if [[ \"\$pid\" =~ ^[0-9]+\$ ]]; then ps -o pid,ppid,stat,etime,rss,cmd -p \"\$pid\" || true; else echo 'No server PID file found.'; fi; echo '--- listening port ---'; ss -ltnp 2>/dev/null | grep ':$(framework_port "$framework") ' || true; echo '--- last 120 server log lines ---'; tail -n 120 '$log_file' 2>/dev/null || echo 'Server log not found: $log_file'" >&2
}

# Start one benchmark server on the remote server node. The stop command must
# complete first, so a new server can never overlap a previous controlled one.
start_server() {
  local framework="$1"
  local size="$2"
  stop_server
  echo "==> Starting server framework=$framework size=$size"
  remote "cd '$REMOTE_WORKSPACE' && $(remote_export_prefix) FRAMEWORK='$framework' SIZE='$size' ./benchmark-jfed/scripts/server/start-controlled.sh"
  wait_for_server "$framework" "$size"
}

# Stop the current remote server and wait until its complete cgroup is empty.
stop_server() {
  remote "cd '$REMOTE_WORKSPACE' && $(remote_export_prefix) ./benchmark-jfed/scripts/server/stop-controlled.sh"
}

# Start server CPU/RAM monitoring on the remote server node. The monitor follows
# the whole process tree rooted at the server PID and writes a CSV file.
start_server_monitor() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local remote_file="$REMOTE_SERVER_METRICS_ROOT/$size/$framework/$cache/c$concurrency/server-resources.csv"
  remote "mkdir -p '$(dirname "$remote_file")'; cd '$REMOTE_WORKSPACE'; pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server.pid'); nohup node '$REMOTE_BENCHMARK_DIR/scripts/metrics/monitor-process-tree.js' --pid \"\$pid\" --out '$remote_file' --interval '$SAMPLE_INTERVAL_MS' >/tmp/watdiv-server-monitor.log 2>&1 & echo \$! > '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid'"
  echo "$remote_file"
}

# Stop the remote server monitor after a client run finishes.
stop_server_monitor() {
  remote "if [[ -f '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid' ]]; then kill \$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid') >/dev/null 2>&1 || true; rm -f '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid'; fi" >/dev/null 2>&1 || true
}

# Copy the remote server resource CSV back to the controller node.
pull_server_metrics() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local remote_file="$5"
  local local_file="$LOCAL_SERVER_METRICS_ROOT/$size/$framework/$cache/c$concurrency/server-resources.csv"
  mkdir -p "$(dirname "$local_file")"
  rsync -az "$SERVER_SSH:$remote_file" "$local_file"
  echo "$local_file"
}

# Build the physical-client-node distribution for a requested global concurrency
# level. In remote mode, offsets are global client ids. In local mode, this keeps
# the old single-node behavior.
prepare_client_distribution() {
  local concurrency="$1"
  ACTIVE_CLIENT_NODES=()
  ACTIVE_RUN_LABELS=()
  ACTIVE_LOCAL_CLIENTS=()
  ACTIVE_CLIENT_OFFSETS=()

  if ! use_remote_clients; then
    local local_clients="$concurrency"
    if (( local_clients > MAX_CLIENTS_PER_NODE )); then
      echo "Concurrency $concurrency exceeds MAX_CLIENTS_PER_NODE=$MAX_CLIENTS_PER_NODE in single-node mode." >&2
      exit 1
    fi
    ACTIVE_CLIENT_NODES=("local")
    ACTIVE_RUN_LABELS=("")
    ACTIVE_LOCAL_CLIENTS=("$local_clients")
    ACTIVE_CLIENT_OFFSETS=("$CLIENT_ID_OFFSET")
    return
  fi

  local node_count="$PHYSICAL_CLIENT_COUNT"
  if (( concurrency > TOTAL_CLIENT_CAPACITY )); then
    echo "Concurrency $concurrency exceeds the total physical-client capacity of $TOTAL_CLIENT_CAPACITY." >&2
    exit 1
  fi
  local offset=0
  for ((index = 0; index < node_count; index++)); do
    local node="local"
    if [[ "$index" -gt 0 ]]; then
      node="${CLIENT_NODES[$((index - 1))]}"
    fi
    local base="$((concurrency / node_count))"
    local remainder="$((concurrency % node_count))"
    local local_clients="$base"
    if [[ "$index" -lt "$remainder" ]]; then
      local_clients="$((local_clients + 1))"
    fi
    local capacity="${CLIENT_CAPACITIES[$index]}"
    local node_offset="$offset"
    offset="$((offset + capacity))"
    if [[ "$local_clients" -eq 0 ]]; then
      continue
    fi
    if (( local_clients > capacity )); then
      echo "Concurrency $concurrency needs $local_clients clients on $node, above its capacity of $capacity." >&2
      exit 1
    fi
    ACTIVE_CLIENT_NODES+=("$node")
    ACTIVE_RUN_LABELS+=("client-node-$((index + 1))")
    ACTIVE_LOCAL_CLIENTS+=("$local_clients")
    ACTIVE_CLIENT_OFFSETS+=("$node_offset")
  done
}

client_run_root() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local run_label="$5"
  local root="$RESULTS_ROOT/$size/$framework/$cache/c$concurrency"
  if [[ -n "$run_label" ]]; then
    root="$root/$run_label"
  fi
  echo "$root"
}

start_client_monitors() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  if [[ "$ENABLE_CLIENT_NETNS_MONITOR" != "1" || -z "$NETNS_PREFIX" ]]; then
    return
  fi

  for index in "${!ACTIVE_CLIENT_NODES[@]}"; do
    local node="${ACTIVE_CLIENT_NODES[$index]}"
    local run_label="${ACTIVE_RUN_LABELS[$index]}"
    local local_clients="${ACTIVE_LOCAL_CLIENTS[$index]}"
    local offset="${ACTIVE_CLIENT_OFFSETS[$index]}"
    local pid_file="$REMOTE_CLIENT_BENCHMARK_DIR/tmp/jfed-client-netns-monitor-${run_label:-local}.pid"
    local out_file
    if [[ "$node" == "local" ]]; then
      out_file="$(client_run_root "$framework" "$size" "$cache" "$concurrency" "$run_label")/client-netns.csv"
      mkdir -p "$(dirname "$out_file")" "$TMP_ROOT"
      sudo -E env COUNT="$local_clients" CLIENT_ID_OFFSET="$offset" NETNS_PREFIX="$NETNS_PREFIX" OUT="$out_file" \
        "$SCRIPT_DIR/../client/monitor-netns.sh" >/tmp/watdiv-client-netns-monitor.log 2>&1 &
      echo "$!" > "$TMP_ROOT/jfed-client-netns-monitor-local.pid"
    else
      out_file="$REMOTE_CLIENT_RESULTS_ROOT/$size/$framework/$cache/c$concurrency/$run_label/client-netns.csv"
      remote_client "$node" "mkdir -p '$(dirname "$out_file")' '$REMOTE_CLIENT_BENCHMARK_DIR/tmp'; cd '$REMOTE_CLIENT_WORKSPACE'; sudo -E env $(remote_client_export_prefix) COUNT='$local_clients' CLIENT_ID_OFFSET='$offset' OUT='$out_file' ./benchmark-jfed/scripts/client/monitor-netns.sh >/tmp/watdiv-client-netns-monitor-$run_label.log 2>&1 & echo \$! > '$pid_file'"
    fi
  done
}

stop_client_monitors() {
  if [[ "$ENABLE_CLIENT_NETNS_MONITOR" != "1" || -z "$NETNS_PREFIX" ]]; then
    return
  fi

  for index in "${!ACTIVE_CLIENT_NODES[@]}"; do
    local node="${ACTIVE_CLIENT_NODES[$index]}"
    local run_label="${ACTIVE_RUN_LABELS[$index]}"
    local pid_file="$REMOTE_CLIENT_BENCHMARK_DIR/tmp/jfed-client-netns-monitor-${run_label:-local}.pid"
    if [[ "$node" == "local" ]]; then
      local local_pid_file="$TMP_ROOT/jfed-client-netns-monitor-local.pid"
      if [[ -f "$local_pid_file" ]]; then
        sudo kill "$(cat "$local_pid_file")" >/dev/null 2>&1 || true
        rm -f "$local_pid_file"
      fi
    else
      remote_client "$node" "if [[ -f '$pid_file' ]]; then sudo kill \$(cat '$pid_file') >/dev/null 2>&1 || true; rm -f '$pid_file'; fi" >/dev/null 2>&1 || true
    fi
  done
}

run_local_client_slice() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local local_clients="$5"
  local offset="$6"
  local run_label="$7"

  echo "==> Running local clients framework=$framework size=$size cache=$cache concurrency=$concurrency localClients=$local_clients offset=$offset"
  sudo -E env SERVER_IP="$SERVER_IP" \
  FRAMEWORK="$framework" \
  SIZE="$size" \
  CACHE="$cache" \
  LOCAL_CLIENTS="$local_clients" \
  TOTAL_CONCURRENCY="$concurrency" \
  CLIENT_ID_OFFSET="$offset" \
  RUN_LABEL="$run_label" \
  ITERATIONS="$ITERATIONS" \
  QUERY_LIMIT="$QUERY_LIMIT" \
  NETNS_PREFIX="$NETNS_PREFIX" \
  CLIENT_CPU_MAX="$CLIENT_CPU_MAX" \
  CLIENT_MEMORY_MAX="$CLIENT_MEMORY_MAX" \
  CLIENT_CGROUP_ROOT="$CLIENT_CGROUP_ROOT" \
  RETAIN_QUERY_OUTPUTS="$RETAIN_QUERY_OUTPUTS" \
  KEEP_CLIENT_CACHES="$KEEP_CLIENT_CACHES" \
    "$SCRIPT_DIR/../client/run-slice.sh"
}

run_remote_client_slice() {
  local node="$1"
  local run_label="$2"
  local framework="$3"
  local size="$4"
  local cache="$5"
  local concurrency="$6"
  local local_clients="$7"
  local offset="$8"

  echo "==> Running remote clients node=$node label=$run_label framework=$framework size=$size cache=$cache concurrency=$concurrency localClients=$local_clients offset=$offset"
  remote_client "$node" \
    "cd '$REMOTE_CLIENT_WORKSPACE' && sudo -E env $(remote_client_export_prefix) FRAMEWORK='$framework' SIZE='$size' CACHE='$cache' LOCAL_CLIENTS='$local_clients' TOTAL_CONCURRENCY='$concurrency' CLIENT_ID_OFFSET='$offset' RUN_LABEL='$run_label' ITERATIONS='$ITERATIONS' QUERY_LIMIT='$QUERY_LIMIT' ./benchmark-jfed/scripts/client/run-slice.sh"
}

run_client_workload() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"

  if ! use_remote_clients; then
    run_local_client_slice "$framework" "$size" "$cache" "$concurrency" \
      "${ACTIVE_LOCAL_CLIENTS[0]}" "${ACTIVE_CLIENT_OFFSETS[0]}" "${ACTIVE_RUN_LABELS[0]}"
    return
  fi

  local pids=()
  for index in "${!ACTIVE_CLIENT_NODES[@]}"; do
    if [[ "${ACTIVE_CLIENT_NODES[$index]}" == "local" ]]; then
      run_local_client_slice "$framework" "$size" "$cache" "$concurrency" \
        "${ACTIVE_LOCAL_CLIENTS[$index]}" "${ACTIVE_CLIENT_OFFSETS[$index]}" "${ACTIVE_RUN_LABELS[$index]}" &
    else
      run_remote_client_slice "${ACTIVE_CLIENT_NODES[$index]}" "${ACTIVE_RUN_LABELS[$index]}" \
        "$framework" "$size" "$cache" "$concurrency" "${ACTIVE_LOCAL_CLIENTS[$index]}" "${ACTIVE_CLIENT_OFFSETS[$index]}" &
    fi
    pids+=("$!")
  done

  local status=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      status=1
    fi
  done
  return "$status"
}

pull_remote_client_results() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local server_metrics_file="$5"

  if ! use_remote_clients; then
    node "$BENCHMARK_DIR/scripts/metrics/merge-server-resource-summary.js" \
      --run-root "$(client_run_root "$framework" "$size" "$cache" "$concurrency" "")" \
      --server-resource-file "$server_metrics_file"
    return
  fi

  for index in "${!ACTIVE_CLIENT_NODES[@]}"; do
    local node="${ACTIVE_CLIENT_NODES[$index]}"
    local run_label="${ACTIVE_RUN_LABELS[$index]}"
    local local_run_root
    local_run_root="$(client_run_root "$framework" "$size" "$cache" "$concurrency" "$run_label")"
    if [[ "$node" != "local" ]]; then
      local remote_run_root="$REMOTE_CLIENT_RESULTS_ROOT/$size/$framework/$cache/c$concurrency/$run_label"
      mkdir -p "$local_run_root"
      rsync -az --delete "$node:$remote_run_root/" "$local_run_root/" >/dev/null 2>&1
    fi
    node "$BENCHMARK_DIR/scripts/metrics/merge-server-resource-summary.js" \
      --run-root "$local_run_root" \
      --server-resource-file "$server_metrics_file"
  done
}

# Always stop the server and monitor on exit so a failed benchmark does not leave
# a process consuming the server node.
cleanup() {
  stop_client_monitors
  stop_server_monitor
  stop_server >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Main benchmark loop:
#   size -> framework -> cache mode -> concurrency
#
# For every selected combination, start the correct server, monitor it, run the
# clients, merge metrics, then stop the server before the next combination.
for size in $SIZES; do
  for framework in $FRAMEWORKS; do
    if [[ "$RESTART_SERVER_PER_RUN" != "1" ]]; then
      start_server "$framework" "$size"
    fi

    for cache in $(cache_modes_for_framework "$framework"); do
      for concurrency in $CONCURRENCY; do
        if [[ "$RESTART_SERVER_PER_RUN" == "1" ]]; then
          start_server "$framework" "$size"
        fi

        prepare_client_distribution "$concurrency"
        server_metrics_file="$(start_server_monitor "$framework" "$size" "$cache" "$concurrency")"
        start_client_monitors "$framework" "$size" "$cache" "$concurrency"
        set +e
        run_client_workload "$framework" "$size" "$cache" "$concurrency"
        status=$?
        set -e
        stop_client_monitors
        stop_server_monitor
        local_server_metrics_file="$(pull_server_metrics "$framework" "$size" "$cache" "$concurrency" "$server_metrics_file")"
        pull_remote_client_results "$framework" "$size" "$cache" "$concurrency" "$local_server_metrics_file"

        if [[ "$RESTART_SERVER_PER_RUN" == "1" ]]; then
          stop_server
        fi
        if [[ "$status" -ne 0 ]]; then
          echo "Benchmark failed for framework=$framework size=$size cache=$cache concurrency=$concurrency" >&2
          exit "$status"
        fi
      done
    done

    if [[ "$RESTART_SERVER_PER_RUN" != "1" ]]; then
      stop_server
    fi
  done
done

# Rebuild the global aggregate CSV once the full matrix has completed.
RESULTS_ROOT="$RESULTS_ROOT" node "$BENCHMARK_DIR/scripts/analysis/aggregate-results.js"
RESULTS_ROOT="$RESULTS_ROOT" node "$BENCHMARK_DIR/scripts/analysis/aggregate-network.js"
echo "Full benchmark complete. Results: $RESULTS_ROOT"
