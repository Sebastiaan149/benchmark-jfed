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

python3 "$SCRIPT_DIR/../analysis/plot-results.py" "$PROFILE"
