#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

CLIENT_SSHS="${CLIENT_SSHS:-}"
REMOTE_CLIENT_WORKSPACE="${REMOTE_CLIENT_WORKSPACE:-$WORKSPACE_ROOT}"
REMOTE_CLIENT_BENCHMARK_DIR="${REMOTE_CLIENT_BENCHMARK_DIR:-$REMOTE_CLIENT_WORKSPACE/benchmark-jfed}"
SIZES="${SIZES:-1m 10m 50m 100m}"

SIZES="$SIZES" "$SCRIPT_DIR/pull-query-files-from-server.sh"

read -r -a client_nodes <<< "$CLIENT_SSHS"
for node in "${client_nodes[@]}"; do
  for size in $SIZES; do
    echo "==> Syncing $size query inputs to $node"
    ssh -o BatchMode=yes "$node" "mkdir -p '$REMOTE_CLIENT_BENCHMARK_DIR/data/$size'"
    rsync -az \
      "$DATA_ROOT/$size/queries" \
      "$DATA_ROOT/$size/manifest.json" \
      "$node:$REMOTE_CLIENT_BENCHMARK_DIR/data/$size/"
  done
done
