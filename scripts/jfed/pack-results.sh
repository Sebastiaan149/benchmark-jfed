#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BENCHMARK_DIR/downloads}"
archive="$DOWNLOAD_DIR/watdiv-results-$(date +%Y%m%d-%H%M%S).tgz"

[[ -d "$BENCHMARK_DIR/watdiv-results" ]] || { echo "Missing watdiv-results; run a benchmark profile first." >&2; exit 1; }
[[ -d "$BENCHMARK_DIR/logs" ]] || { echo "Missing logs; run a benchmark profile first." >&2; exit 1; }
mkdir -p "$DOWNLOAD_DIR"
tar -C "$BENCHMARK_DIR" -czf "$archive" watdiv-results logs
echo "Created $archive. Download it from client0 through jFed or SCP."
