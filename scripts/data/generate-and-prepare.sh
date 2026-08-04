#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}"
export SIZES
export FRAMEWORKS

all_sizes="$SIZES"

check_server_disk() {
  local size="$1"
  local minimum_gib
  case "$size" in
    1m) minimum_gib="${MIN_FREE_GIB_1M:-10}" ;;
    10m) minimum_gib="${MIN_FREE_GIB_10M:-40}" ;;
    50m) minimum_gib="${MIN_FREE_GIB_50M:-180}" ;;
    100m) minimum_gib="${MIN_FREE_GIB_100M:-350}" ;;
    *) echo "No server disk requirement is defined for size $size." >&2; exit 1 ;;
  esac
  mkdir -p "$DATA_ROOT"
  local available_gib
  available_gib="$(df --output=avail -BG "$DATA_ROOT" | tail -n 1 | tr -dc '0-9')"
  if [[ ! "$available_gib" =~ ^[0-9]+$ ]] || (( available_gib < minimum_gib )); then
    echo "Preparing $size requires at least ${minimum_gib} GiB free at $DATA_ROOT; ${available_gib:-0} GiB are available." >&2
    exit 1
  fi
  echo "Server disk preflight passed for $size: minimum=${minimum_gib}GiB available=${available_gib}GiB."
}

for size in $all_sizes; do
  echo "==> Generating and preparing $size before moving to the next size"
  check_server_disk "$size"
  SIZES="$size" "$SCRIPT_DIR/00-generate-data.sh"
  SIZES="$size" "$SCRIPT_DIR/01-prepare-derived-data.sh"
  SIZES="$size" "$SCRIPT_DIR/storage-report.sh"
done
