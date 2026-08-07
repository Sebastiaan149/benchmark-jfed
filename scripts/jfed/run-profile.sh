#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

for command in node ssh rsync curl sudo; do
  require_command "$command"
done
node -e "require.resolve('@comunica/query-sparql-hdt', { paths: [ process.argv[1] ] })" "$BENCHMARK_DIR" >/dev/null

PROFILE="${1:-}"
case "$PROFILE" in
  smoke-1m)
    sizes="1m"
    run_script="$SCRIPT_DIR/run-smoke.sh"
    profile_results="$BENCHMARK_DIR/watdiv-results/smoke-1m"
    ;;
  full)
    sizes="1m 10m 50m 100m"
    profile_results="$BENCHMARK_DIR/watdiv-results/full"
    ;;
  *)
    echo "Usage: $0 smoke-1m|full" >&2
    exit 1
    ;;
esac

if [[ "$PROFILE" == "smoke-1m" ]]; then
  SIZES="$sizes" "$SCRIPT_DIR/../client/pull-query-files-from-server.sh"
  sudo -E env \
    WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    BENCHMARK_DIR="$BENCHMARK_DIR" \
    COUNT=1 \
    CLIENT_ID_OFFSET=0 \
    NODE_INDEX=0 \
    SERVER_IP="$SERVER_IP" \
    NETNS_PREFIX="$NETNS_PREFIX" \
    CLIENT_SUBNET_PREFIX="$CLIENT_SUBNET_PREFIX" \
    CLIENT_RATE="$CLIENT_RATE" \
    NAMESPACE_LATENCY_MS="$NAMESPACE_LATENCY_MS" \
      "$SCRIPT_DIR/../client/setup-netns.sh"
else
  echo "==> Removing incomplete or previous full-profile results"
  sudo rm -rf "$profile_results"
  ssh -o BatchMode=yes "$SERVER_SSH" "sudo rm -rf '$REMOTE_BENCHMARK_DIR/watdiv-results/full'"
  read -r -a remote_clients <<< "$CLIENT_SSHS"
  for node in "${remote_clients[@]}"; do
    ssh -o BatchMode=yes "$node" "sudo rm -rf '$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results/full'"
  done
  SIZES="$sizes" "$SCRIPT_DIR/prepare-clients.sh"
  RESULTS_ROOT="$profile_results" "$SCRIPT_DIR/calibrate-network.sh"
fi

if [[ "$PROFILE" == "smoke-1m" ]]; then
  RESULTS_ROOT="$profile_results" \
  REMOTE_RESULTS_ROOT="$REMOTE_BENCHMARK_DIR/watdiv-results/$PROFILE" \
  REMOTE_CLIENT_RESULTS_ROOT="$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results/$PROFILE" \
    "$run_script"
else
  single_results="$profile_results/single-unlimited"
  concurrent_results="$profile_results/concurrent-limited"
  sudo rm -rf "$single_results" "$concurrent_results"

  echo "==> Configuring the unlimited client at 100 Mbit/s"
  sudo -E env \
    WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    BENCHMARK_DIR="$BENCHMARK_DIR" \
    COUNT=1 \
    MAX_CLIENTS_PER_NODE="${CLIENT_NODE_CAPACITIES%% *}" \
    CLIENT_ID_OFFSET=0 \
    NODE_INDEX=0 \
    SERVER_IP="$SERVER_IP" \
    NETNS_PREFIX="$NETNS_PREFIX" \
    CLIENT_SUBNET_PREFIX="$CLIENT_SUBNET_PREFIX" \
    CLIENT_RATE="100mbit" \
    NAMESPACE_LATENCY_MS="$NAMESPACE_LATENCY_MS" \
      "$SCRIPT_DIR/../client/setup-netns.sh"

  echo "==> Full benchmark 1/2: one unlimited client, 50 queries, one iteration, 100 Mbit/s"
  RESULTS_ROOT="$single_results" \
  REMOTE_RESULTS_ROOT="$REMOTE_BENCHMARK_DIR/watdiv-results/full/single-unlimited" \
  REMOTE_CLIENT_RESULTS_ROOT="$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results/full/single-unlimited" \
  CONCURRENCY="1" \
  ITERATIONS="1" \
  QUERY_SELECTION="hundred" \
  QUERY_LIMIT="50" \
  CLIENT_CPU_MAX="max" \
  CLIENT_MEMORY_MAX="max" \
  CLIENT_NODE_OPTIONS="--max-old-space-size=57344" \
    "$SCRIPT_DIR/run-full.sh"

  echo "==> Restoring all logical clients at $CLIENT_RATE before the concurrency benchmark"
  TOTAL_CLIENTS="$TOTAL_CLIENTS" CLIENT_RATE="$CLIENT_RATE" "$SCRIPT_DIR/../client/setup-cluster.sh"

  echo "==> Full benchmark 2/2: limited clients, ten queries, one iteration"
  RESULTS_ROOT="$concurrent_results" \
  REMOTE_RESULTS_ROOT="$REMOTE_BENCHMARK_DIR/watdiv-results/full/concurrent-limited" \
  REMOTE_CLIENT_RESULTS_ROOT="$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results/full/concurrent-limited" \
  CONCURRENCY="1 2 4 8 16 32 64" \
  ITERATIONS="1" \
  QUERY_SELECTION="ten" \
    "$SCRIPT_DIR/run-full.sh"
fi

echo "Benchmark profile $PROFILE complete: $profile_results"
