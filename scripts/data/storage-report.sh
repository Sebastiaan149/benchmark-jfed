#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"

printf 'Filesystem usage for %s:\n' "$DATA_ROOT"
df -h "$DATA_ROOT"
printf '\nPrepared data:\n'
for size in $SIZES; do
  data_dir="$(size_dir "$size")"
  if [[ -d "$data_dir" ]]; then
    du -sh "$data_dir"
    for path in dataset.nt dataset.hdt dataset.hdt.cs partitioning typed-partitioning passage; do
      if [[ -e "$data_dir/$path" ]]; then
        du -sh "$data_dir/$path"
      fi
    done
  fi
done
