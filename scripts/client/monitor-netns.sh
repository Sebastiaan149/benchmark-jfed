#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

COUNT="${COUNT:-64}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
PREFIX="${NETNS_PREFIX:-bench-c}"
OUT="${OUT:-$RESULTS_ROOT/client-netns.csv}"
INTERVAL="${INTERVAL:-1}"
APPEND="${APPEND:-0}"

mkdir -p "$(dirname "$OUT")"
if [[ "$APPEND" != "1" || ! -s "$OUT" ]]; then
  echo "timestamp;client;rxBytes;txBytes;rxPackets;txPackets" > "$OUT"
fi

sample_all() {
  ts="$(date --iso-8601=ns)"
  for i in $(seq 1 "$COUNT"); do
    client_id="$((CLIENT_ID_OFFSET + i))"
    ns="${PREFIX}${client_id}"
    link="benchv${client_id}"
    if ip netns exec "$ns" test -d "/sys/class/net/$link/statistics" >/dev/null 2>&1; then
      rx_b="$(ip netns exec "$ns" cat "/sys/class/net/$link/statistics/rx_bytes")"
      tx_b="$(ip netns exec "$ns" cat "/sys/class/net/$link/statistics/tx_bytes")"
      rx_p="$(ip netns exec "$ns" cat "/sys/class/net/$link/statistics/rx_packets")"
      tx_p="$(ip netns exec "$ns" cat "/sys/class/net/$link/statistics/tx_packets")"
      echo "$ts;$client_id;$rx_b;$tx_b;$rx_p;$tx_p" >> "$OUT"
    fi
  done
}

trap 'sample_all; exit 0' INT TERM

while true; do
  sample_all
  sleep "$INTERVAL"
done
