#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

require_root
require_command ip
require_command iptables
require_command tc

COUNT="${COUNT:-1}"
MAX_CLIENTS_PER_NODE="${MAX_CLIENTS_PER_NODE:?Set the physical-node client limit}"
CLIENT_ID_OFFSET="${CLIENT_ID_OFFSET:-0}"
NODE_INDEX="${NODE_INDEX:-0}"
SERVER_IP="${SERVER_IP:?Missing benchmark server LAN address}"
IFACE="${IFACE:-$(detect_experiment_iface "$SERVER_IP")}"
PREFIX="${NETNS_PREFIX:-bench-c}"
SUBNET_PREFIX="${CLIENT_SUBNET_PREFIX:-10.200}"
RATE="${CLIENT_RATE:-20mbit}"
LATENCY_MS="${NAMESPACE_LATENCY_MS:-0}"

if [[ -z "$IFACE" ]]; then
  echo "Could not detect the routed interface for $SERVER_IP; set IFACE manually." >&2
  exit 1
fi
if (( COUNT > MAX_CLIENTS_PER_NODE )); then
  echo "At most $MAX_CLIENTS_PER_NODE logical clients are allowed per physical client node; requested $COUNT." >&2
  exit 1
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
node_subnet="$SUBNET_PREFIX.$NODE_INDEX.0/24"
iptables -t nat -C POSTROUTING -s "$node_subnet" -o "$IFACE" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$node_subnet" -o "$IFACE" -j MASQUERADE
iptables -C FORWARD -s "$node_subnet" -o "$IFACE" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$node_subnet" -o "$IFACE" -j ACCEPT
iptables -C FORWARD -d "$node_subnet" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -d "$node_subnet" -i "$IFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

for ((local_index = 1; local_index <= COUNT; local_index++)); do
  client_id="$((CLIENT_ID_OFFSET + local_index))"
  namespace="${PREFIX}${client_id}"
  host_link="bvh${client_id}"
  namespace_link="benchv${client_id}"
  block_start="$(((local_index - 1) * 4))"
  host_ip="$SUBNET_PREFIX.$NODE_INDEX.$((block_start + 1))"
  client_ip="$SUBNET_PREFIX.$NODE_INDEX.$((block_start + 2))"

  ip netns del "$namespace" >/dev/null 2>&1 || true
  ip link del "$host_link" >/dev/null 2>&1 || true

  ip netns add "$namespace"
  ip link add "$host_link" type veth peer name "$namespace_link"
  ip link set "$namespace_link" netns "$namespace"
  ip addr add "$host_ip/30" dev "$host_link"
  ip link set "$host_link" up
  ip netns exec "$namespace" ip addr add "$client_ip/30" dev "$namespace_link"
  ip netns exec "$namespace" ip link set "$namespace_link" up
  ip netns exec "$namespace" ip link set lo up
  ip netns exec "$namespace" ip route add default via "$host_ip"

  if [[ "$LATENCY_MS" != "0" ]]; then
    ip netns exec "$namespace" tc qdisc add dev "$namespace_link" root netem delay "${LATENCY_MS}ms" rate "$RATE"
    tc qdisc add dev "$host_link" root netem delay "${LATENCY_MS}ms" rate "$RATE"
  else
    ip netns exec "$namespace" tc qdisc add dev "$namespace_link" root tbf rate "$RATE" burst 256kb latency 400ms
    tc qdisc add dev "$host_link" root tbf rate "$RATE" burst 256kb latency 400ms
  fi

  ip netns exec "$namespace" ping -c 1 -W 2 "$SERVER_IP" >/dev/null
done

echo "Created $COUNT NAT-backed logical clients on $IFACE in $node_subnet at $RATE per client."
echo "Logical client ids: $((CLIENT_ID_OFFSET + 1))-$((CLIENT_ID_OFFSET + COUNT)); server: $SERVER_IP."
