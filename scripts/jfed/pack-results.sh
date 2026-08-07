#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../config/cluster.env
source "$BENCHMARK_DIR/config/cluster.env"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BENCHMARK_DIR/downloads}"
archive="$DOWNLOAD_DIR/watdiv-results-$(date +%Y%m%d-%H%M%S).tgz"

[[ -d "$BENCHMARK_DIR/watdiv-results" ]] || { echo "Missing watdiv-results; run a benchmark profile first." >&2; exit 1; }
mkdir -p "$DOWNLOAD_DIR" "$BENCHMARK_DIR/logs/server0"
rsync -a "$SERVER_SSH:$REMOTE_BENCHMARK_DIR/logs/" "$BENCHMARK_DIR/logs/server0/"

# Interrupted runs may predate per-iteration cleanup. Never archive transient client state.
find "$BENCHMARK_DIR/watdiv-results" -type d \( \
  -name home -o \
  -name tmp -o \
  -name .smartkg-cache -o \
  -name .wisekg-cache \
  \) -prune -exec rm -rf -- {} +

tar -C "$BENCHMARK_DIR" \
  --exclude='*/home' \
  --exclude='*/home/*' \
  --exclude='*/tmp' \
  --exclude='*/tmp/*' \
  --exclude='*/.smartkg-cache' \
  --exclude='*/.smartkg-cache/*' \
  --exclude='*/.wisekg-cache' \
  --exclude='*/.wisekg-cache/*' \
  -czf "$archive" watdiv-results logs
echo "Created $archive. Download it from client0 through jFed or SCP."
