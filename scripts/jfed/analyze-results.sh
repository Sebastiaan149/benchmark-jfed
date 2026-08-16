#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-}"
case "$PROFILE" in
  smoke-1m|full)
    ;;
  *)
    echo "Usage: $0 smoke-1m|full" >&2
    exit 1
    ;;
esac

RESULTS_ROOT="$SCRIPT_DIR/../../watdiv-results/$PROFILE"
node "$SCRIPT_DIR/../analysis/aggregate-nginx-cache.js" "$RESULTS_ROOT"
if [[ "$PROFILE" == "full" ]]; then
  for result_set in single-unlimited concurrent-limited; do
    if [[ -d "$RESULTS_ROOT/$result_set" ]]; then
      node "$SCRIPT_DIR/../analysis/aggregate-stage-timeseries.js" "$RESULTS_ROOT/$result_set"
    fi
  done
else
  node "$SCRIPT_DIR/../analysis/aggregate-stage-timeseries.js" "$RESULTS_ROOT"
fi
python3 "$SCRIPT_DIR/../analysis/plot-results.py" "$PROFILE"
