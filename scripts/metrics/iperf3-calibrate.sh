#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
SERVER_IP="${SERVER_IP:?Missing benchmark server LAN address}"
DURATION_SECONDS="${DURATION_SECONDS:-30}"
CLIENTS="${CLIENTS:-1}"
JSON_OUT="${JSON_OUT:-iperf3.json}"

case "$ROLE" in
  server)
    exec iperf3 -s
    ;;
  client)
    iperf3 -c "$SERVER_IP" -t "$DURATION_SECONDS" -P "$CLIENTS" -J > "$JSON_OUT"
    echo "Wrote $JSON_OUT"
    ;;
  *)
    echo "Usage: $0 server|client" >&2
    exit 1
    ;;
esac
