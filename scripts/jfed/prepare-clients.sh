#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"

echo "==> Copying query files from the server to all physical client nodes"
SIZES="$SIZES" "$SCRIPT_DIR/../client/sync-inputs.sh"

echo "==> Creating $TOTAL_CLIENTS isolated logical clients across three pcgen07-1p nodes ($CLIENT_NODE_CAPACITIES)"
TOTAL_CLIENTS="$TOTAL_CLIENTS" "$SCRIPT_DIR/../client/setup-cluster.sh"

echo "Client preparation complete."
