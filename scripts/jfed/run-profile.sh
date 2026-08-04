#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

PROFILE="${1:-}"
case "$PROFILE" in
  smoke-1m)
    sizes="1m"
    run_script="$SCRIPT_DIR/run-smoke.sh"
    profile_results="$BENCHMARK_DIR/watdiv-results/smoke-1m"
    ;;
  full)
    sizes="1m 10m 50m 100m"
    run_script="$SCRIPT_DIR/run-full.sh"
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
  SIZES="$sizes" "$SCRIPT_DIR/prepare-clients.sh"
  RESULTS_ROOT="$profile_results" "$SCRIPT_DIR/calibrate-network.sh"
fi

RESULTS_ROOT="$profile_results" \
REMOTE_RESULTS_ROOT="$REMOTE_BENCHMARK_DIR/watdiv-results/$PROFILE" \
REMOTE_CLIENT_RESULTS_ROOT="$REMOTE_CLIENT_BENCHMARK_DIR/watdiv-results/$PROFILE" \
  "$run_script"

echo "Benchmark profile $PROFILE complete: $profile_results"
