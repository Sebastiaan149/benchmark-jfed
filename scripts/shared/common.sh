#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_ROOT="$REPO_ROOT/scripts"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$REPO_ROOT/config/cluster.env}"

if [[ -f "$CLUSTER_CONFIG" ]]; then
  # shellcheck source=../../config/cluster.env
  source "$CLUSTER_CONFIG"
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
BENCHMARK_DIR="${BENCHMARK_DIR:-$REPO_ROOT}"
DATA_ROOT="${DATA_ROOT:-$BENCHMARK_DIR/data}"
RESULTS_ROOT="${RESULTS_ROOT:-$BENCHMARK_DIR/watdiv-results}"
LOG_ROOT="${LOG_ROOT:-$BENCHMARK_DIR/logs}"
TMP_ROOT="${TMP_ROOT:-$BENCHMARK_DIR/tmp}"
CONFIG_FILE="${CONFIG_FILE:-$BENCHMARK_DIR/config/frameworks.json}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

detect_experiment_iface() {
  local server_ip="${1:?Pass the benchmark server LAN address}"
  ip route get "$server_ip" | awk '/ dev / { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

json_value() {
  node -e "const fs=require('fs'); const value=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log($2)" "$1"
}
