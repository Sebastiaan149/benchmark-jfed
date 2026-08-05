#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

SIZES="${SIZES:-1m}" \
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}" \
CONCURRENCY="${CONCURRENCY:-1}" \
ITERATIONS="${ITERATIONS:-1}" \
QUERY_LIMIT="${QUERY_LIMIT:-0}" \
QUERY_SELECTION="${QUERY_SELECTION:-five}" \
RESTART_SERVER_PER_RUN=1 \
  "$SCRIPT_DIR/../run/full-experiment.sh"
