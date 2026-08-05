#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

SIZES="${SIZES:-1m 10m 50m 100m}" \
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}" \
CONCURRENCY="${CONCURRENCY:-1 2 4 8 16 32 64}" \
ITERATIONS="${ITERATIONS:-1}" \
QUERY_LIMIT="${QUERY_LIMIT:-0}" \
QUERY_SELECTION="${QUERY_SELECTION:-ten}" \
CLIENT_CPU_MAX="${CLIENT_CPU_MAX:-}" \
CLIENT_MEMORY_MAX="${CLIENT_MEMORY_MAX:-}" \
CLIENT_NODE_OPTIONS="${CLIENT_NODE_OPTIONS:-}" \
RESTART_SERVER_PER_RUN="${RESTART_SERVER_PER_RUN:-1}" \
  "$SCRIPT_DIR/../run/full-experiment.sh"
