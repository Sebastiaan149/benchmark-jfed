#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BENCHMARK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../config/cluster.env
source "$LOCAL_BENCHMARK_DIR/config/cluster.env"

for command in ssh scp tar; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

temporary_dir="$(mktemp -d)"
archive="$temporary_dir/benchmark-jfed.tgz"
trap 'rm -rf "$temporary_dir"' EXIT

tar -C "$(dirname "$LOCAL_BENCHMARK_DIR")" \
  --exclude='benchmark-jfed/.git' \
  --exclude='benchmark-jfed/data' \
  --exclude='benchmark-jfed/watdiv-results' \
  --exclude='benchmark-jfed/downloads' \
  --exclude='benchmark-jfed/logs' \
  --exclude='benchmark-jfed/tmp' \
  --exclude='benchmark-jfed/node_modules' \
  -czf "$archive" benchmark-jfed

read -r -a remote_clients <<< "$CLIENT_SSHS"
targets=("$SERVER_SSH" "${remote_clients[@]}")
for target in "${targets[@]}"; do
  echo "==> Deploying benchmark-jfed to $target"
  ssh -o BatchMode=yes "$target" "sudo mkdir -p '$WORKSPACE_ROOT' && sudo chown \"\$(id -un):\$(id -gn)\" '$WORKSPACE_ROOT'"
  scp -q "$archive" "$target:/tmp/benchmark-jfed.tgz"
  ssh -o BatchMode=yes "$target" "tar -C '$WORKSPACE_ROOT' -xzf /tmp/benchmark-jfed.tgz"
done

echo "==> Installing server software on server0"
ssh -o BatchMode=yes "$SERVER_SSH" "cd '$WORKSPACE_ROOT' && ./benchmark-jfed/scripts/setup/server.sh"

echo "==> Installing client software on client0"
cd "$WORKSPACE_ROOT"
"$BENCHMARK_DIR/scripts/setup/client.sh"

echo "==> Installing client software on client1 and client2"
pids=()
for target in "${remote_clients[@]}"; do
  ssh -o BatchMode=yes "$target" "cd '$WORKSPACE_ROOT' && ./benchmark-jfed/scripts/setup/client.sh" &
  pids+=("$!")
done
status=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    status=1
  fi
done
if [[ "$status" -ne 0 ]]; then
  echo "At least one client installation failed." >&2
  exit "$status"
fi

"$SCRIPT_DIR/verify-cluster.sh"
echo "Cluster deployment complete."
