#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BENCHMARK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../config/cluster.env
source "$LOCAL_BENCHMARK_DIR/config/cluster.env"

for command in ssh rsync; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

sync_target() {
  local target="$1"
  local destination="$2"
  echo "==> Syncing benchmark scripts and configuration to $target"
  ssh -o BatchMode=yes "$target" "mkdir -p '$destination'"
  rsync -az --delete \
    --exclude='/.git/' \
    --exclude='/data/' \
    --exclude='/watdiv-results/' \
    --exclude='/downloads/' \
    --exclude='/logs/' \
    --exclude='/tmp/' \
    --exclude='/node_modules/' \
    "$LOCAL_BENCHMARK_DIR/" "$target:$destination/"
}

sync_target "$SERVER_SSH" "$REMOTE_BENCHMARK_DIR"
read -r -a remote_clients <<< "$CLIENT_SSHS"
for target in "${remote_clients[@]}"; do
  sync_target "$target" "$REMOTE_CLIENT_BENCHMARK_DIR"
done

echo "Benchmark scripts and configuration are synchronized."
