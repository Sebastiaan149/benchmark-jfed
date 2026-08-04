#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

machine_check='set -e; test "$(nproc)" -eq 6; test "$(awk '\''/MemTotal/ { print $2 }'\'' /proc/meminfo)" -ge 60000000; test "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs; grep -qw cpu /sys/fs/cgroup/cgroup.controllers; grep -qw memory /sys/fs/cgroup/cgroup.controllers; for tool in node npm yarn git python3 ip iptables tc iperf3 ps sar tcpdump curl rsync; do command -v "$tool" >/dev/null; done; python3 -c "import pandas, matplotlib"; hostname; nproc; free -h; df -h /; ip -brief address'

echo "==> client0"
bash -lc "$machine_check"

read -r -a remote_clients <<< "$CLIENT_SSHS"
for target in "$SERVER_SSH" "${remote_clients[@]}"; do
  echo "==> $target"
  ssh -o BatchMode=yes "$target" "$machine_check"
done

read -r -a client_ips <<< "$CLIENT_IPS"
for ip_address in "$SERVER_IP" "${client_ips[@]:1}"; do
  ping -c 2 "$ip_address"
done

node -e "require.resolve('@comunica/query-sparql-hdt', { paths: [ process.argv[1] ] }); console.log('client0 Comunica HDT client OK')" \
  "$BENCHMARK_DIR"
for target in "${remote_clients[@]}"; do
  ssh -o BatchMode=yes "$target" \
    "node -e \"require.resolve('@comunica/query-sparql-hdt', { paths: [ process.argv[1] ] }); console.log('remote Comunica HDT client OK')\" '$REMOTE_CLIENT_BENCHMARK_DIR'"
done

ssh -o BatchMode=yes "$SERVER_SSH" \
  "set -e; hard_limit=\$(ulimit -Hn); if [[ \"\$hard_limit\" != unlimited ]] && (( hard_limit < 131072 )); then echo \"Server nofile hard limit is too low: \$hard_limit\" >&2; exit 1; fi; node --version; java -version; mvn --version | head -n 2; docker info >/dev/null; df -h '$WORKSPACE_ROOT'"
echo "jFed cluster verification complete."
