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
ITERATIONS="${ITERATIONS:-1}"
QUERY_LIMIT="${QUERY_LIMIT:-0}"
QUERY_SELECTION="${QUERY_SELECTION:-five}"
QUERY_ORDER="${QUERY_ORDER:-fixed}"
CACHE_MODES="${CACHE_MODES:-auto}"
# When enabled, compare server caching only: uncached frameworks run once with
# cold clients, while nginx partners run cold followed by server-warm.
SERVER_CACHE_EXPERIMENT="${SERVER_CACHE_EXPERIMENT:-0}"
CONCURRENCY_MAJOR_ORDER="${CONCURRENCY_MAJOR_ORDER:-0}"

# Logical-client controls. These allow one physical client node to run many
# isolated logical clients, or multiple physical client nodes to split the same
# global client-id range.
CLIENT_NODE_CAPACITIES="${CLIENT_NODE_CAPACITIES:?Set the capacities for all physical client nodes}"
MAX_CLIENTS_PER_NODE="${MAX_CLIENTS_PER_NODE:?Set the physical-node client limit}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
NETNS_PREFIX="${NETNS_PREFIX:-bench-c}"
CLIENT_CPU_MAX="${CLIENT_CPU_MAX:-}"
CLIENT_MEMORY_MAX="${CLIENT_MEMORY_MAX:-}"
CLIENT_NODE_OPTIONS="${CLIENT_NODE_OPTIONS:-}"
CLIENT_CGROUP_ROOT="${CLIENT_CGROUP_ROOT:-/sys/fs/cgroup/watdiv-clients}"
CLIENT_SSHS="${CLIENT_SSHS:-}"
ENABLE_CLIENT_NETNS_MONITOR="${ENABLE_CLIENT_NETNS_MONITOR:-1}"
RETAIN_QUERY_OUTPUTS="${RETAIN_QUERY_OUTPUTS:-0}"
KEEP_CLIENT_CACHES="${KEEP_CLIENT_CACHES:-0}"
# The full profile enables this for its concurrent-client benchmark so each
# concurrency level starts without retained client or filesystem cache state.
CLEAR_CACHES_BETWEEN_CONCURRENCY="${CLEAR_CACHES_BETWEEN_CONCURRENCY:-0}"

SERVER_STARTUP_SECONDS="${SERVER_STARTUP_SECONDS:-60}"
SAMPLE_INTERVAL_MS="${SAMPLE_INTERVAL_MS:-1000}"

# If set to 1, restart the server for every framework/size/cache/concurrency
# run. This is slower, but it avoids cache and JVM/Node warm-state differences
# between concurrency levels.
RESTART_SERVER_PER_RUN="${RESTART_SERVER_PER_RUN:-1}"

# Store server-side monitoring files under a timestamped run id, then copy them
# back to the client node after each run.
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
QUERY_ORDER_SEED="${QUERY_ORDER_SEED:-$RUN_ID}"
LOCAL_SERVER_METRICS_ROOT="$RESULTS_ROOT/server-metrics/$RUN_ID"
REMOTE_SERVER_METRICS_ROOT="$REMOTE_RESULTS_ROOT/server-metrics/$RUN_ID"
mkdir -p "$LOCAL_SERVER_METRICS_ROOT"
FAILURE_LOG="$RESULTS_ROOT/benchmark-attempt-failures.csv"
QUERY_FAILURE_LOG="$RESULTS_ROOT/benchmark-query-failures.csv"
MAX_MINOR_QUERY_FAILURES="${MAX_MINOR_QUERY_FAILURES:-5}"
MAX_MINOR_QUERY_FAILURE_PERCENT="${MAX_MINOR_QUERY_FAILURE_PERCENT:-10}"
failure_count=0
CANCEL_REQUESTED=0
CLEANUP_STARTED=0
if [[ ! -f "$FAILURE_LOG" ]]; then
  echo 'timestamp;runId;phase;size;framework;cacheMode;concurrency;classification;status;resultRoot;serverLog' > "$FAILURE_LOG"
fi
SERVER_INCIDENT_LOG="$RESULTS_ROOT/benchmark-server-incidents.csv"
if [[ ! -f "$SERVER_INCIDENT_LOG" ]]; then
  echo 'timestamp;runId;size;framework;cacheMode;concurrency;incident;action;archivedServerLog' > "$SERVER_INCIDENT_LOG"
fi

record_failure() {
  local phase="$1"
  local size="$2"
  local framework="$3"
  local cache="$4"
  local concurrency="$5"
  local status="$6"
  local classification="${7:-recoverable-query-failure}"
  printf '%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n' \
    "$(date --iso-8601=seconds)" "$RUN_ID" "$phase" "$size" "$framework" "$cache" "$concurrency" \
    "$classification" "$status" "$RESULTS_ROOT/$size/$framework/$cache/c$concurrency" \
    "$REMOTE_BENCHMARK_DIR/logs/jfed/server-$size-$framework.log" >> "$FAILURE_LOG"
  failure_count="$((failure_count + 1))"
}

classify_query_failures() {
  local size="$1"
  local framework="$2"
  local cache="$3"
  local concurrency="$4"
  node "$BENCHMARK_DIR/scripts/analysis/classify-query-failures.js" \
    --run-root "$RESULTS_ROOT/$size/$framework/$cache/c$concurrency" \
    --detail-log "$QUERY_FAILURE_LOG" \
    --max-minor-failures "$MAX_MINOR_QUERY_FAILURES" \
    --max-minor-failure-percent "$MAX_MINOR_QUERY_FAILURE_PERCENT" \
    --run-id "$RUN_ID" \
    --size "$size" \
    --framework "$framework" \
    --cache "$cache" \
    --concurrency "$concurrency" \
    --server-log "$REMOTE_BENCHMARK_DIR/logs/jfed/server-$size-$framework.log"
}

server_process_is_alive() {
  remote "pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server.pid' 2>/dev/null || true); [[ \"\$pid\" =~ ^[0-9]+\$ ]] && kill -0 \"\$pid\" 2>/dev/null"
}

server_log_reports_crash() {
  local framework="$1"
  local size="$2"
  remote "grep -qE 'forcefully killed with (SIGKILL|9)|Killing main process as well' '$REMOTE_BENCHMARK_DIR/logs/jfed/server-$size-$framework.log'"
}

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
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=3 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$SERVER_SSH" "$@"
}

remote_client() {
  local client="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=3 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$client" "$@"
}

use_remote_clients() {
  [[ "${#CLIENT_NODES[@]}" -gt 0 ]]
}

# Build a safely quoted environment prefix for remote server commands.
remote_export_prefix() {
  printf 'WORKSPACE_ROOT=%q BENCHMARK_DIR=%q DATA_ROOT=%q RESULTS_ROOT=%q CONFIG_FILE=%q SERVER_IP=%q SAMPLE_INTERVAL_MS=%q ' \
    "$REMOTE_WORKSPACE" "$REMOTE_BENCHMARK_DIR" "$REMOTE_BENCHMARK_DIR/data" "$REMOTE_RESULTS_ROOT" "$REMOTE_BENCHMARK_DIR/config/frameworks.json" "$SERVER_IP" "$SAMPLE_INTERVAL_MS"
}

remote_client_export_prefix() {
  printf 'WORKSPACE_ROOT=%q BENCHMARK_DIR=%q DATA_ROOT=%q RESULTS_ROOT=%q CONFIG_FILE=%q SERVER_IP=%q NETNS_PREFIX=%q CLIENT_CPU_MAX=%q CLIENT_MEMORY_MAX=%q CLIENT_CGROUP_ROOT=%q RETAIN_QUERY_OUTPUTS=%q KEEP_CLIENT_CACHES=%q ' \
    "$REMOTE_CLIENT_WORKSPACE" "$REMOTE_CLIENT_BENCHMARK_DIR" "$REMOTE_CLIENT_BENCHMARK_DIR/data" "$REMOTE_CLIENT_RESULTS_ROOT" "$REMOTE_CLIENT_BENCHMARK_DIR/config/frameworks.json" "$SERVER_IP" "$NETNS_PREFIX" "$CLIENT_CPU_MAX" "$CLIENT_MEMORY_MAX" "$CLIENT_CGROUP_ROOT" "$RETAIN_QUERY_OUTPUTS" "$KEEP_CLIENT_CACHES"
}

clear_runtime_caches_between_concurrency_levels() {
  local size="$1"
  local framework="$2"
  local cache="$3"
  local concurrency="$4"
  local local_run_root="$RESULTS_ROOT/$size/$framework/$cache/c$concurrency"
  local remote_run_root="$REMOTE_CLIENT_RESULTS_ROOT/$size/$framework/$cache/c$concurrency"

  echo "==> Clearing disposable caches and filesystem page cache after $framework $size $cache c$concurrency"

  # Keep result CSVs, metrics, logs, and failure records. Only runtime caches
  # are disposable between concurrency levels.
  find "$local_run_root" -type d \
    \( -name home -o -name tmp -o -name .smartkg-cache -o -name .wisekg-cache \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'

  for node in "${CLIENT_NODES[@]}"; do
    remote_client "$node" "find '$remote_run_root' -type d \\
      \\( -name home -o -name tmp -o -name .smartkg-cache -o -name .wisekg-cache \\) \\
      -prune -exec rm -rf {} + 2>/dev/null || true; sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
  done

  # The server is stopped before this function is called. Dropping the page
  # cache here avoids retaining its dataset and partition files for the next
  # concurrency level.
  remote "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'"
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
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); const f=c.frameworks[process.argv[2]]; if (f.healthPath) { console.log('http://' + process.argv[3] + ':' + process.argv[4] + f.healthPath); } else { const s=f.source.replaceAll('localhost', process.argv[3]).replaceAll('{port}', process.argv[4]); console.log(s.includes('@') ? s.split('@').pop() : s); }" \
    "$CONFIG_FILE" "$framework" "$SERVER_IP" "$port"
}

# Cache modes are framework-specific by default. For example, SmartKG-like
# systems may have cold and warm runs, while simple endpoints usually only use
# cold runs.
cache_modes_for_framework() {
  if [[ "$SERVER_CACHE_EXPERIMENT" == "1" && "$1" != *-cache ]]; then
    echo "cold"
  elif [[ "$CACHE_MODES" != "auto" ]]; then
    echo "$CACHE_MODES"
  else
    node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log((c.frameworks[process.argv[2]].cacheModes || ['cold']).join(' '))" \
      "$CONFIG_FILE" "$1"
  fi
}

# Return success when this framework is configured to run a cold nginx
# measurement immediately followed by a server-warm measurement.
uses_server_warm_pair() {
  local framework="$1"
  [[ "$framework" == *-cache ]] || return 1
  cache_modes_for_framework "$framework" | tr ' ' '\n' | grep -qx 'server-warm'
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
  local server_run_label="${3:-$RUN_ID}"
  local preserve_nginx_cache="${4:-0}"
  stop_server
  echo "==> Starting server framework=$framework size=$size"
  remote "cd '$REMOTE_WORKSPACE' && $(remote_export_prefix) FRAMEWORK='$framework' SIZE='$size' SERVER_RUN_LABEL='$server_run_label' PRESERVE_NGINX_CACHE='$preserve_nginx_cache' ./benchmark-jfed/scripts/server/start-controlled.sh"
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
  local attempt="${5:-1}"
  local remote_file="$REMOTE_SERVER_METRICS_ROOT/$size/$framework/$cache/c$concurrency/server-resources-attempt-$(printf '%03d' "$attempt").csv"
  local active_arg=""
  if [[ "$framework" == "ldf-dump-hdt" ]]; then
    active_arg="--active-file '$REMOTE_BENCHMARK_DIR/tmp/hdt-dump-active-transfers'"
  fi
  local launch_attempt=0
  local max_launch_attempts=5
  while (( launch_attempt < max_launch_attempts )); do
    launch_attempt="$((launch_attempt + 1))"
    if remote "
      monitor_pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid' 2>/dev/null || true)
      if [[ \"\$monitor_pid\" =~ ^[0-9]+\$ ]] && kill -0 \"\$monitor_pid\" 2>/dev/null && [[ -s '$remote_file' ]]; then
        exit 0
      fi
      if [[ \"\$monitor_pid\" =~ ^[0-9]+\$ ]]; then kill \"\$monitor_pid\" >/dev/null 2>&1 || true; fi
      rm -f '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid' '$remote_file'
      mkdir -p '$(dirname "$remote_file")' || exit 1
      cd '$REMOTE_WORKSPACE' || exit 1
      pid=\$(cat '$REMOTE_BENCHMARK_DIR/tmp/jfed-server.pid') || exit 1
      nohup node '$REMOTE_BENCHMARK_DIR/scripts/metrics/monitor-process-tree.js' --pid \"\$pid\" --out '$remote_file' --interval '$SAMPLE_INTERVAL_MS' $active_arg >/tmp/watdiv-server-monitor.log 2>&1 &
      monitor_pid=\$!
      echo \"\$monitor_pid\" > '$REMOTE_BENCHMARK_DIR/tmp/jfed-server-monitor.pid' || exit 1
      for _attempt in \$(seq 1 20); do
        if [[ -s '$remote_file' ]] && kill -0 \"\$monitor_pid\" 2>/dev/null; then exit 0; fi
        if ! kill -0 \"\$monitor_pid\" 2>/dev/null; then break; fi
        sleep 0.25
      done
      echo 'Server resource monitor failed to create $remote_file.' >&2
      tail -n 80 /tmp/watdiv-server-monitor.log >&2 2>/dev/null || true
      exit 1
    "; then
      echo "$remote_file"
      return 0
    fi
    if (( launch_attempt < max_launch_attempts )); then
      echo "Server resource monitor launch attempt $launch_attempt/$max_launch_attempts failed for $framework $size $cache c$concurrency; retrying in 5 seconds." >&2
      sleep 5
    fi
  done
  echo "Server resource monitor failed after $max_launch_attempts attempts for $framework $size $cache c$concurrency; terminating the benchmark." >&2
  return 1
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
  local local_file="$LOCAL_SERVER_METRICS_ROOT/$size/$framework/$cache/c$concurrency/$(basename "$remote_file")"
  mkdir -p "$(dirname "$local_file")"
  rsync -az "$SERVER_SSH:$remote_file" "$local_file"
  if [[ "$framework" == *-cache ]]; then
    local active_cache_label="$cache"
    if [[ "$cache" == "server-warm" ]]; then
      # The paired measurements intentionally keep the same nginx process.
      # Its configured log filename therefore retains the cold run label.
      active_cache_label="cold"
    fi
    local remote_cache_log_name="nginx-$size-$framework-$RUN_ID-$active_cache_label-c$concurrency-access.log"
    local local_cache_log_name="nginx-$size-$framework-$RUN_ID-$cache-c$concurrency-access.log"
    rsync -az "$SERVER_SSH:$REMOTE_BENCHMARK_DIR/logs/jfed/$remote_cache_log_name" \
      "$(dirname "$local_file")/$local_cache_log_name"
  fi
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

ensure_client_run_root() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local run_root
  run_root="$(client_run_root "$framework" "$size" "$cache" "$concurrency" "")"

  # A previous privileged slice may have created this shared parent as root.
  # Normalize it before local and remote node-specific result directories are
  # created. This is intentionally non-recursive: each slice restores ownership
  # of its own files when it exits.
  sudo mkdir -p "$run_root"
  sudo chown "$(id -u):$(id -g)" "$run_root"
}

start_client_monitors() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local append="${5:-0}"
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
      sudo -E env COUNT="$local_clients" CLIENT_ID_OFFSET="$offset" NETNS_PREFIX="$NETNS_PREFIX" OUT="$out_file" APPEND="$append" \
        "$SCRIPT_DIR/../client/monitor-netns.sh" >/tmp/watdiv-client-netns-monitor.log 2>&1 &
      echo "$!" > "$TMP_ROOT/jfed-client-netns-monitor-local.pid"
    else
      out_file="$REMOTE_CLIENT_RESULTS_ROOT/$size/$framework/$cache/c$concurrency/$run_label/client-netns.csv"
      remote_client "$node" "mkdir -p '$(dirname "$out_file")' '$REMOTE_CLIENT_BENCHMARK_DIR/tmp'; cd '$REMOTE_CLIENT_WORKSPACE'; sudo -E env $(remote_client_export_prefix) COUNT='$local_clients' CLIENT_ID_OFFSET='$offset' OUT='$out_file' APPEND='$append' ./benchmark-jfed/scripts/client/monitor-netns.sh >/tmp/watdiv-client-netns-monitor-$run_label.log 2>&1 & echo \$! > '$pid_file'"
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
  local workload_phase="$8"
  local resume="${9:-0}"

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
  QUERY_SELECTION="$QUERY_SELECTION" \
  QUERY_ORDER="$QUERY_ORDER" \
  QUERY_ORDER_SEED="$QUERY_ORDER_SEED" \
  NETNS_PREFIX="$NETNS_PREFIX" \
  CLIENT_CPU_MAX="$CLIENT_CPU_MAX" \
  CLIENT_MEMORY_MAX="$CLIENT_MEMORY_MAX" \
  CLIENT_CGROUP_ROOT="$CLIENT_CGROUP_ROOT" \
  RETAIN_QUERY_OUTPUTS="$RETAIN_QUERY_OUTPUTS" \
  KEEP_CLIENT_CACHES="$KEEP_CLIENT_CACHES" \
  WORKLOAD_PHASE="$workload_phase" \
  RESUME="$resume" \
  CLIENT_NODE_OPTIONS="$CLIENT_NODE_OPTIONS" \
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
  local workload_phase="$9"
  local resume="${10:-0}"

  echo "==> Running remote clients node=$node label=$run_label framework=$framework size=$size cache=$cache concurrency=$concurrency localClients=$local_clients offset=$offset"
  remote_client "$node" \
    "cd '$REMOTE_CLIENT_WORKSPACE' && sudo -E env $(remote_client_export_prefix) FRAMEWORK='$framework' SIZE='$size' CACHE='$cache' LOCAL_CLIENTS='$local_clients' TOTAL_CONCURRENCY='$concurrency' CLIENT_ID_OFFSET='$offset' RUN_LABEL='$run_label' ITERATIONS='$ITERATIONS' QUERY_LIMIT='$QUERY_LIMIT' QUERY_SELECTION='$QUERY_SELECTION' QUERY_ORDER='$QUERY_ORDER' QUERY_ORDER_SEED='$QUERY_ORDER_SEED' WORKLOAD_PHASE='$workload_phase' RESUME='$resume' CLIENT_NODE_OPTIONS='$CLIENT_NODE_OPTIONS' ./benchmark-jfed/scripts/client/run-slice.sh"
}

run_client_workload() {
  local framework="$1"
  local size="$2"
  local cache="$3"
  local concurrency="$4"
  local workload_phase="${5:-both}"
  local resume="${6:-0}"

  if ! use_remote_clients; then
    run_local_client_slice "$framework" "$size" "$cache" "$concurrency" \
      "${ACTIVE_LOCAL_CLIENTS[0]}" "${ACTIVE_CLIENT_OFFSETS[0]}" "${ACTIVE_RUN_LABELS[0]}" "$workload_phase" "$resume"
    return
  fi

  local pids=()
  for index in "${!ACTIVE_CLIENT_NODES[@]}"; do
    if [[ "${ACTIVE_CLIENT_NODES[$index]}" == "local" ]]; then
      run_local_client_slice "$framework" "$size" "$cache" "$concurrency" \
        "${ACTIVE_LOCAL_CLIENTS[$index]}" "${ACTIVE_CLIENT_OFFSETS[$index]}" "${ACTIVE_RUN_LABELS[$index]}" "$workload_phase" "$resume" &
    else
      run_remote_client_slice "${ACTIVE_CLIENT_NODES[$index]}" "${ACTIVE_RUN_LABELS[$index]}" \
        "$framework" "$size" "$cache" "$concurrency" "${ACTIVE_LOCAL_CLIENTS[$index]}" "${ACTIVE_CLIENT_OFFSETS[$index]}" "$workload_phase" "$resume" &
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
  local server_failure_count="${6:-0}"
  local recovery_warning=""
  if (( server_failure_count > 0 )); then
    recovery_warning="WARNING: server exited unexpectedly and was restarted $server_failure_count time(s), interrupted queries were retained as failures and skipped during recovery."
  fi

  if ! use_remote_clients; then
    node "$BENCHMARK_DIR/scripts/metrics/merge-server-resource-summary.js" \
      --run-root "$(client_run_root "$framework" "$size" "$cache" "$concurrency" "")" \
      --server-resource-file "$server_metrics_file" \
      --server-downtime-count "$server_failure_count" \
      --server-recovery-warning "$recovery_warning"
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
      rsync -az --delete \
        --exclude='home/' \
        --exclude='tmp/' \
        --exclude='.smartkg-cache/' \
        --exclude='.wisekg-cache/' \
        "$node:$remote_run_root/" "$local_run_root/" >/dev/null 2>&1
    fi
    node "$BENCHMARK_DIR/scripts/metrics/merge-server-resource-summary.js" \
      --run-root "$local_run_root" \
      --server-resource-file "$server_metrics_file" \
      --server-downtime-count "$server_failure_count" \
      --server-recovery-warning "$recovery_warning"
  done
}

combine_server_metrics() {
  local output="$1"
  shift
  mkdir -p "$(dirname "$output")"
  if [[ "$#" -eq 0 ]]; then
    echo 'timestamp;pid;processCount;cpuPercent;rssMb;commands' > "$output"
    return
  fi
  head -n 1 "$1" > "$output"
  for file in "$@"; do
    tail -n +2 "$file" >> "$output"
  done
}

archive_server_incident() {
  local size="$1"
  local framework="$2"
  local cache="$3"
  local concurrency="$4"
  local incident="$5"
  local archive="$REMOTE_BENCHMARK_DIR/logs/jfed/incidents/server-$size-$framework-$RUN_ID-incident-$(printf '%03d' "$incident").log"
  remote "mkdir -p '$(dirname "$archive")'; cp '$REMOTE_BENCHMARK_DIR/logs/jfed/server-$size-$framework.log' '$archive'"
  printf '%s;%s;%s;%s;%s;%s;%s;%s;%s\n' \
    "$(date --iso-8601=seconds)" "$RUN_ID" "$size" "$framework" "$cache" "$concurrency" \
    "$incident" restarted-and-resumed "$archive" >> "$SERVER_INCIDENT_LOG"
  echo "$archive"
}

# Always stop the server and monitor on exit so a failed benchmark does not leave
# a process consuming the server node.
stop_active_client_workloads() {
  sudo pkill -TERM -f "$BENCHMARK_DIR/scripts/client/run-slice.sh" >/dev/null 2>&1 || true
  sudo pkill -TERM -f "$BENCHMARK_DIR/scripts/benchmark/run-benchmark.js" >/dev/null 2>&1 || true
  sudo pkill -TERM -f "$WORKSPACE_ROOT/comunicaMT/engines/.*/bin/query.js" >/dev/null 2>&1 || true

  for node in "${CLIENT_NODES[@]}"; do
    remote_client "$node" "sudo pkill -TERM -f '$REMOTE_CLIENT_BENCHMARK_DIR/scripts/client/run-slice.sh' >/dev/null 2>&1 || true; \
      sudo pkill -TERM -f '$REMOTE_CLIENT_BENCHMARK_DIR/scripts/benchmark/run-benchmark.js' >/dev/null 2>&1 || true; \
      sudo pkill -TERM -f '$REMOTE_CLIENT_WORKSPACE/comunicaMT/engines/.*/bin/query.js' >/dev/null 2>&1 || true" \
      >/dev/null 2>&1 || true
  done
}

cleanup() {
  if [[ "$CLEANUP_STARTED" == "1" ]]; then
    return
  fi
  CLEANUP_STARTED=1
  stop_client_monitors
  stop_server_monitor
  stop_server >/dev/null 2>&1 || true
}

cancel_benchmark() {
  local signal="$1"
  if [[ "$CANCEL_REQUESTED" == "1" ]]; then
    return
  fi
  CANCEL_REQUESTED=1
  trap - INT TERM
  echo >&2
  echo "Manual $signal received; stopping clients and server without retrying." >&2
  stop_active_client_workloads
  cleanup
  exit 130
}

trap cleanup EXIT
trap 'cancel_benchmark SIGINT' INT
trap 'cancel_benchmark SIGTERM' TERM

run_combination() {
  local size="$1"
  local framework="$2"
  local cache="$3"
  local concurrency="$4"
  local preserve_nginx_cache=0
  local is_server_warm_pair=0
  if uses_server_warm_pair "$framework"; then
    is_server_warm_pair=1
  fi
  if [[ "$framework" == *-cache && "$cache" == "server-warm" ]]; then
    preserve_nginx_cache=1
  fi
  ensure_client_run_root "$framework" "$size" "$cache" "$concurrency"
  if [[ "$RESTART_SERVER_PER_RUN" == "1" ]]; then
    if [[ "$cache" == "server-warm" && "$is_server_warm_pair" == "1" ]]; then
      if ! server_process_is_alive; then
        echo "The server-warm measurement requires the preceding cold nginx server to remain active." >&2
        exit 1
      fi
      echo "==> Reusing nginx and its populated cache for framework=$framework size=$size c$concurrency"
    else
      start_server "$framework" "$size" "$RUN_ID-$cache-c$concurrency" "$preserve_nginx_cache"
    fi
  fi

  prepare_client_distribution "$concurrency"
  if [[ "$cache" == "warm" ]]; then
    echo "==> Warming client and server caches before measurement"
    set +e
    run_client_workload "$framework" "$size" "$cache" "$concurrency" warmup
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
      record_failure warmup "$size" "$framework" "$cache" "$concurrency" "$status" fatal-warmup-failure
      echo "Warmup failed for framework=$framework size=$size concurrency=$concurrency; continuing with the measured run." >&2
    fi
  fi
  local server_incidents=0 query_failures=0 server_attempt=1 status=0 resume_workload server_metrics_file
  local -a local_server_metric_files=()
  while true; do
    resume_workload=0
    if (( server_attempt > 1 )); then resume_workload=1; fi
    server_metrics_file="$(start_server_monitor "$framework" "$size" "$cache" "$concurrency" "$server_attempt")"
    start_client_monitors "$framework" "$size" "$cache" "$concurrency" "$resume_workload"
    set +e
    if [[ "$cache" == "warm" ]]; then
      run_client_workload "$framework" "$size" "$cache" "$concurrency" measured "$resume_workload"
    else
      run_client_workload "$framework" "$size" "$cache" "$concurrency" both "$resume_workload"
    fi
    status=$?
    set -e
    if [[ "$CANCEL_REQUESTED" == "1" ]]; then
      return 130
    fi
    stop_client_monitors
    stop_server_monitor
    local_server_metric_files+=("$(pull_server_metrics "$framework" "$size" "$cache" "$concurrency" "$server_metrics_file")")
    if [[ "$status" -eq 0 ]]; then break; fi
    sleep 10
    if [[ "$CANCEL_REQUESTED" == "1" ]]; then
      return 130
    fi
    if server_process_is_alive && ! server_log_reports_crash "$framework" "$size"; then
      query_failures="$((query_failures + 1))"
      echo "Query failed but $framework server remains available; skipping it and continuing." >&2
      server_attempt="$((server_attempt + 1))"
      continue
    fi
    server_incidents="$((server_incidents + 1))"
    archived_log="$(archive_server_incident "$size" "$framework" "$cache" "$concurrency" "$server_incidents")"
    record_failure measured "$size" "$framework" "$cache" "$concurrency" "$status" server-outage-restarted
    echo "WARNING: $framework server exited during $size $cache c$concurrency; archived $archived_log." >&2
    echo "==> Restarting server and resuming after recorded query indices"
    start_server "$framework" "$size" "$RUN_ID-$cache-c$concurrency" "$preserve_nginx_cache"
    server_attempt="$((server_attempt + 1))"
  done

  local combined_server_metrics="$LOCAL_SERVER_METRICS_ROOT/$size/$framework/$cache/c$concurrency/server-resources.csv"
  combine_server_metrics "$combined_server_metrics" "${local_server_metric_files[@]}"
  pull_remote_client_results "$framework" "$size" "$cache" "$concurrency" "$combined_server_metrics" "$server_incidents"
  if [[ "$status" -ne 0 ]]; then
    local classification_status=0
    classify_query_failures "$size" "$framework" "$cache" "$concurrency" || classification_status=$?
    if [[ "$classification_status" -eq 10 ]] && server_process_is_alive; then
      record_failure measured "$size" "$framework" "$cache" "$concurrency" "$status" recoverable-query-failure
      echo "Recoverable query failures for framework=$framework size=$size cache=$cache concurrency=$concurrency; continuing." >&2
    else
      record_failure measured "$size" "$framework" "$cache" "$concurrency" "$status" fatal-processing-failure
      echo "Fatal benchmark failure for framework=$framework size=$size cache=$cache concurrency=$concurrency." >&2
      show_server_diagnostics "$framework" "$size"
      exit "$status"
    fi
  elif (( server_incidents > 0 || query_failures > 0 )); then
    classify_query_failures "$size" "$framework" "$cache" "$concurrency" >/dev/null 2>&1 || true
  fi
  if [[ "$framework" == *-cache && "$cache" == "cold" && "$is_server_warm_pair" == "1" ]]; then
    # The cold access log has already been copied locally. Start the warm
    # measurement with an empty log while leaving nginx, its origin, and all
    # cached response files untouched.
    remote ": > '$REMOTE_BENCHMARK_DIR/logs/jfed/nginx-$size-$framework-$RUN_ID-cold-c$concurrency-access.log'"
  elif [[ "$RESTART_SERVER_PER_RUN" == "1" ]]; then
    stop_server
  fi
  # A cached framework's cold measurement is deliberately the population pass
  # for its immediately following server-warm measurement. Keep that nginx
  # cache (including the OS page cache) until both measurements are complete.
  if [[ "$CLEAR_CACHES_BETWEEN_CONCURRENCY" == "1" &&
    !( "$framework" == *-cache && "$cache" == "cold" && "$is_server_warm_pair" == "1" ) ]]; then
    clear_runtime_caches_between_concurrency_levels "$size" "$framework" "$cache" "$concurrency"
  fi
}

# Default order is size -> framework -> cache -> concurrency. The concurrent
# profile uses concurrency-major order so no framework inherits its own earlier
# low-concurrency cache state.
if [[ "$CONCURRENCY_MAJOR_ORDER" == "1" ]]; then
  if [[ "$RESTART_SERVER_PER_RUN" != "1" ]]; then
    echo 'CONCURRENCY_MAJOR_ORDER requires RESTART_SERVER_PER_RUN=1.' >&2
    exit 1
  fi
  for size in $SIZES; do
    for concurrency in $CONCURRENCY; do
      for framework in $FRAMEWORKS; do
        for cache in $(cache_modes_for_framework "$framework"); do
          run_combination "$size" "$framework" "$cache" "$concurrency"
        done
      done
    done
  done
else
  for size in $SIZES; do
    for framework in $FRAMEWORKS; do
      if [[ "$RESTART_SERVER_PER_RUN" != "1" ]]; then start_server "$framework" "$size"; fi
      for cache in $(cache_modes_for_framework "$framework"); do
        for concurrency in $CONCURRENCY; do
          run_combination "$size" "$framework" "$cache" "$concurrency"
        done
      done
      if [[ "$RESTART_SERVER_PER_RUN" != "1" ]]; then stop_server; fi
    done
  done
fi

# Rebuild the global aggregate CSV once the full matrix has completed.
RESULTS_ROOT="$RESULTS_ROOT" node "$BENCHMARK_DIR/scripts/analysis/aggregate-results.js"
RESULTS_ROOT="$RESULTS_ROOT" node "$BENCHMARK_DIR/scripts/analysis/aggregate-network.js"
node "$BENCHMARK_DIR/scripts/analysis/aggregate-stage-timeseries.js" "$RESULTS_ROOT"
echo "Full benchmark complete. Results: $RESULTS_ROOT"
if (( failure_count > 0 )); then
  echo "Completed with $failure_count recoverable benchmark combinations. Failure logs: $FAILURE_LOG and $QUERY_FAILURE_LOG" >&2
fi
