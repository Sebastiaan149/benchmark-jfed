#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

DURATION_SECONDS="${DURATION_SECONDS:-10}"
CALIBRATION_DIR="$RESULTS_ROOT/calibration"
mkdir -p "$CALIBRATION_DIR"

read -r -a remote_clients <<< "$CLIENT_SSHS"
read -r -a client_capacities <<< "${CLIENT_NODE_CAPACITIES:?Set the capacities for all physical client nodes}"
nodes=("local" "${remote_clients[@]}")
if (( ${#client_capacities[@]} != ${#nodes[@]} )); then
  echo "CLIENT_NODE_CAPACITIES has ${#client_capacities[@]} entries, but calibration found ${#nodes[@]} physical client nodes." >&2
  exit 1
fi

ports=()
for index in "${!nodes[@]}"; do
  ports+=("$((5201 + index))")
done
port_list="${ports[*]}"
ssh -o BatchMode=yes "$SERVER_SSH" \
  "pkill -x iperf3 >/dev/null 2>&1 || true; for port in $port_list; do nohup iperf3 -s -p \"\$port\" >/tmp/watdiv-iperf3-\$port.log 2>&1 & done"
trap 'ssh -o BatchMode=yes "$SERVER_SSH" "pkill -x iperf3 >/dev/null 2>&1 || true"' EXIT INT TERM
sleep 1

pids=()
outputs=()
remote_outputs=()
for index in "${!nodes[@]}"; do
  node="${nodes[$index]}"
  port="${ports[$index]}"
  parallel_streams="${client_capacities[$index]}"
  output="$CALIBRATION_DIR/client-node-$((index + 1))-physical.json"
  outputs+=("$output")
  echo "==> Starting $parallel_streams experiment-LAN streams from client node $((index + 1))"
  if [[ "$node" == "local" ]]; then
    remote_outputs+=("")
    iperf3 -c "$SERVER_IP" -p "$port" -t "$DURATION_SECONDS" -P "$parallel_streams" -J > "$output" &
  else
    remote_output="$REMOTE_CLIENT_BENCHMARK_DIR/tmp/iperf3-physical-node-$((index + 1)).json"
    remote_outputs+=("$remote_output")
    ssh -o BatchMode=yes "$node" \
      "iperf3 -c '$SERVER_IP' -p '$port' -t '$DURATION_SECONDS' -P '$parallel_streams' -J > '$remote_output'" &
  fi
  pids+=("$!")
done

status=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    status=1
  fi
done
if [[ "$status" -ne 0 ]]; then
  echo "At least one experiment-LAN calibration failed." >&2
  exit "$status"
fi

for index in "${!nodes[@]}"; do
  if [[ "${nodes[$index]}" != "local" ]]; then
    rsync -az "${nodes[$index]}:${remote_outputs[$index]}" "${outputs[$index]}"
  fi
done

summary="$CALIBRATION_DIR/summary.csv"
echo "clientNode;parallelStreams;receivedBitsPerSecond;receivedMbitPerSecond" > "$summary"
aggregate_bps=0
aggregate_streams=0
for index in "${!outputs[@]}"; do
  bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second' "${outputs[$index]}")"
  if [[ ! "$bps" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Could not read received throughput from ${outputs[$index]}." >&2
    exit 1
  fi
  mbps="$(awk -v value="$bps" 'BEGIN { printf "%.3f", value / 1000000 }')"
  aggregate_bps="$(awk -v total="$aggregate_bps" -v value="$bps" 'BEGIN { printf "%.3f", total + value }')"
  parallel_streams="${client_capacities[$index]}"
  aggregate_streams="$((aggregate_streams + parallel_streams))"
  echo "client-node-$((index + 1));$parallel_streams;$bps;$mbps" >> "$summary"
done
aggregate_mbps="$(awk -v value="$aggregate_bps" 'BEGIN { printf "%.3f", value / 1000000 }')"
echo "all-client-nodes;$aggregate_streams;$aggregate_bps;$aggregate_mbps" >> "$summary"

echo "Simultaneous experiment-LAN throughput: $aggregate_mbps Mbit/s"
echo "Calibration summary: $summary"
