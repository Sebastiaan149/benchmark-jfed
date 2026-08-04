#!/usr/bin/env bash
set -euo pipefail

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SHARED_DIR/../.." && pwd)"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$REPO_ROOT/config/cluster.env}"

if [[ -f "$CLUSTER_CONFIG" ]]; then
  # shellcheck source=../../config/cluster.env
  source "$CLUSTER_CONFIG"
fi

BENCHMARK_DIR="${BENCHMARK_DIR:-$REPO_ROOT}"
SCRIPTS_ROOT="$BENCHMARK_DIR/scripts"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$BENCHMARK_DIR/.." && pwd)}"

COMUNICA_DIR="$WORKSPACE_ROOT/comunicaMT"
JBR_DIR="$WORKSPACE_ROOT/jbr.js"
SMARTKG_CREATOR_DIR="$WORKSPACE_ROOT/smartKG-creator-types"
DATA_ROOT="${DATA_ROOT:-$BENCHMARK_DIR/data}"
RESULTS_ROOT="${RESULTS_ROOT:-$BENCHMARK_DIR/watdiv-results}"
LOG_ROOT="${LOG_ROOT:-$BENCHMARK_DIR/logs}"
TMP_ROOT="${TMP_ROOT:-$BENCHMARK_DIR/tmp}"
CONFIG_FILE="${CONFIG_FILE:-$BENCHMARK_DIR/config/frameworks.json}"

mkdir -p "$DATA_ROOT" "$RESULTS_ROOT" "$LOG_ROOT" "$TMP_ROOT"

node_json() {
  local expr="$1"
  shift || true
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log($expr)" "$CONFIG_FILE" "$@"
}

size_dir() {
  echo "$DATA_ROOT/$1"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

require_dir() {
  if [[ ! -d "$1" ]]; then
    echo "Missing required directory: $1" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

framework_port() {
  node_json "c.frameworks[process.argv[2]].port" "$1"
}

framework_server() {
  node_json "c.frameworks[process.argv[2]].server" "$1"
}

framework_source() {
  local framework="$1"
  local port="$2"
  node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.frameworks[process.argv[2]].source.replaceAll('{port}', process.argv[3]))" "$CONFIG_FILE" "$framework" "$port"
}

framework_engine() {
  node_json "c.frameworks[process.argv[2]].engine" "$1"
}

java_opts() {
  local xms xmx
  xms="${JAVA_XMS:-$(node_json 'c.resources.javaXms')}"
  xmx="${JAVA_XMX:-$(node_json 'c.resources.javaXmx')}"
  echo "-Xms$xms -Xmx$xmx"
}

node_options() {
  local max_old
  max_old="${NODE_MAX_OLD_SPACE_SIZE_MB:-$(node_json 'c.resources.serverNodeMaxOldSpaceSizeMb')}"
  echo "--max-old-space-size=$max_old"
}
