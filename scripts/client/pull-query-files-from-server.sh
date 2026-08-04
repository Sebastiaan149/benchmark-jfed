#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

SERVER_SSH="${SERVER_SSH:?Set the benchmark server SSH target}"
REMOTE_WORKSPACE="${REMOTE_WORKSPACE:-$WORKSPACE_ROOT}"
SIZES="${SIZES:-1m 10m 50m 100m}"

for size in $SIZES; do
  mkdir -p "$DATA_ROOT/$size"
  rsync -avz \
    "$SERVER_SSH:$REMOTE_WORKSPACE/benchmark-jfed/data/$size/queries" \
    "$SERVER_SSH:$REMOTE_WORKSPACE/benchmark-jfed/data/$size/manifest.json" \
    "$DATA_ROOT/$size/"
done
