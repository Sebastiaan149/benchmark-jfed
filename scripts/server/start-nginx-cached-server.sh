#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <cached-framework> <size>" >&2
  exit 1
fi

CACHED_FRAMEWORK="$1"
SIZE="$2"
if [[ ! "$CACHED_FRAMEWORK" =~ ^[a-z0-9-]+$ || ! "$SIZE" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "Unsafe cached framework or size identifier." >&2
  exit 1
fi
ORIGIN_FRAMEWORK="$(node_json 'c.frameworks[process.argv[2]].cacheOriginFramework' "$CACHED_FRAMEWORK")"
PUBLIC_PORT="${PORT:-$(framework_port "$CACHED_FRAMEWORK")}"
ORIGIN_PORT="$((PUBLIC_PORT + 1000))"
PREFIX="$TMP_ROOT/nginx-cache-$CACHED_FRAMEWORK-$SIZE"
CACHE_DIR="$PREFIX/cache"
TEMP_DIR="$PREFIX/temp"
CONFIG="$PREFIX/nginx.conf"
SERVER_RUN_LABEL="${SERVER_RUN_LABEL:-manual}"
PRESERVE_NGINX_CACHE="${PRESERVE_NGINX_CACHE:-0}"
if [[ "$PRESERVE_NGINX_CACHE" != "0" && "$PRESERVE_NGINX_CACHE" != "1" ]]; then
  echo "PRESERVE_NGINX_CACHE must be 0 or 1." >&2
  exit 1
fi
if [[ ! "$SERVER_RUN_LABEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Unsafe server run label." >&2
  exit 1
fi
ACCESS_LOG="$LOG_ROOT/jfed/nginx-$SIZE-$CACHED_FRAMEWORK-$SERVER_RUN_LABEL-access.log"
ERROR_LOG="$LOG_ROOT/jfed/nginx-$SIZE-$CACHED_FRAMEWORK-$SERVER_RUN_LABEL-error.log"

require_command nginx
if [[ "$PRESERVE_NGINX_CACHE" != "1" ]]; then
  rm -rf "$PREFIX"
fi
mkdir -p "$CACHE_DIR" "$TEMP_DIR" "$(dirname "$ACCESS_LOG")"
touch "$ACCESS_LOG" "$ERROR_LOG"
node "$SCRIPT_DIR/write-nginx-cache-config.js" \
  "$CONFIG" "$CACHE_DIR" "$TEMP_DIR" "$ACCESS_LOG" "$ERROR_LOG" "$PUBLIC_PORT" "$ORIGIN_PORT"

origin_pid=""
nginx_pid=""
cleanup() {
  [[ -z "$nginx_pid" ]] || kill "$nginx_pid" >/dev/null 2>&1 || true
  [[ -z "$origin_pid" ]] || kill "$origin_pid" >/dev/null 2>&1 || true
  [[ -z "$nginx_pid" ]] || wait "$nginx_pid" >/dev/null 2>&1 || true
  [[ -z "$origin_pid" ]] || wait "$origin_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

PORT="$ORIGIN_PORT" ADVERTISED_PORT="$PUBLIC_PORT" "$SCRIPT_DIR/start-server.sh" "$ORIGIN_FRAMEWORK" "$SIZE" &
origin_pid="$!"
origin_ready=0
for _attempt in $(seq 1 60); do
  if curl -fsS -I "http://127.0.0.1:$ORIGIN_PORT/" >/dev/null 2>&1 ||
    curl -fsS "http://127.0.0.1:$ORIGIN_PORT/" >/dev/null 2>&1; then
    origin_ready=1
    break
  fi
  if ! kill -0 "$origin_pid" >/dev/null 2>&1; then
    echo "Cache origin $ORIGIN_FRAMEWORK exited during startup." >&2
    exit 1
  fi
  sleep 1
done
if [[ "$origin_ready" != "1" ]]; then
  echo "Cache origin $ORIGIN_FRAMEWORK did not become ready on port $ORIGIN_PORT." >&2
  exit 1
fi

nginx -p "$PREFIX/" -c "$CONFIG" -g 'daemon off;' &
nginx_pid="$!"
set +e
wait -n "$origin_pid" "$nginx_pid"
status="$?"
set -e
exit "$status"
