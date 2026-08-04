#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

CLIENT_SSHS="${CLIENT_SSHS:-}"
TOTAL_CLIENTS="${TOTAL_CLIENTS:-64}"
CLIENT_NODE_CAPACITIES="${CLIENT_NODE_CAPACITIES:?Set the capacities for all physical client nodes}"
SERVER_IP="${SERVER_IP:?Set the benchmark server LAN address}"
REMOTE_CLIENT_WORKSPACE="${REMOTE_CLIENT_WORKSPACE:-$WORKSPACE_ROOT}"
REMOTE_CLIENT_BENCHMARK_DIR="${REMOTE_CLIENT_BENCHMARK_DIR:-$REMOTE_CLIENT_WORKSPACE/benchmark-jfed}"
NETNS_PREFIX="${NETNS_PREFIX:-bench-c}"
CLIENT_SUBNET_PREFIX="${CLIENT_SUBNET_PREFIX:-10.200}"
CLIENT_RATE="${CLIENT_RATE:-20mbit}"
NAMESPACE_LATENCY_MS="${NAMESPACE_LATENCY_MS:-0}"

read -r -a client_nodes <<< "$CLIENT_SSHS"
read -r -a client_capacities <<< "$CLIENT_NODE_CAPACITIES"
node_count="$((${#client_nodes[@]} + 1))"

if (( ${#client_capacities[@]} != node_count )); then
  echo "CLIENT_NODE_CAPACITIES has ${#client_capacities[@]} entries, but the cluster has $node_count physical client nodes." >&2
  exit 1
fi

capacity_total=0
for capacity in "${client_capacities[@]}"; do
  capacity_total="$((capacity_total + capacity))"
done
if (( capacity_total != TOTAL_CLIENTS )); then
  echo "Client capacities total $capacity_total, but TOTAL_CLIENTS is $TOTAL_CLIENTS." >&2
  exit 1
fi

base="$((TOTAL_CLIENTS / node_count))"
remainder="$((TOTAL_CLIENTS % node_count))"
offset=0
for ((index = 0; index < node_count; index++)); do
  node="local"
  if [[ "$index" -gt 0 ]]; then
    node="${client_nodes[$((index - 1))]}"
  fi
  count="$base"
  if (( index < remainder )); then
    count="$((count + 1))"
  fi
  capacity="${client_capacities[$index]}"
  if (( count > capacity )); then
    echo "Physical client node $index needs $count clients, above its capacity of $capacity." >&2
    exit 1
  fi
  echo "==> Setting up $count logical clients on $node with id offset $offset"
  if [[ "$node" == "local" ]]; then
    sudo -E env WORKSPACE_ROOT="$WORKSPACE_ROOT" BENCHMARK_DIR="$BENCHMARK_DIR" COUNT="$count" CLIENT_ID_OFFSET="$offset" NODE_INDEX="$index" SERVER_IP="$SERVER_IP" NETNS_PREFIX="$NETNS_PREFIX" CLIENT_SUBNET_PREFIX="$CLIENT_SUBNET_PREFIX" CLIENT_RATE="$CLIENT_RATE" NAMESPACE_LATENCY_MS="$NAMESPACE_LATENCY_MS" \
      "$SCRIPT_DIR/setup-netns.sh"
  else
    ssh -o BatchMode=yes "$node" \
      "cd '$REMOTE_CLIENT_WORKSPACE' && sudo -E env WORKSPACE_ROOT='$REMOTE_CLIENT_WORKSPACE' BENCHMARK_DIR='$REMOTE_CLIENT_BENCHMARK_DIR' COUNT='$count' CLIENT_ID_OFFSET='$offset' NODE_INDEX='$index' SERVER_IP='$SERVER_IP' NETNS_PREFIX='$NETNS_PREFIX' CLIENT_SUBNET_PREFIX='$CLIENT_SUBNET_PREFIX' CLIENT_RATE='$CLIENT_RATE' NAMESPACE_LATENCY_MS='$NAMESPACE_LATENCY_MS' ./benchmark-jfed/scripts/client/setup-netns.sh"
  fi

  offset="$((offset + capacity))"
done
