#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"
require_root

PREFIX="${NETNS_PREFIX:-bench-c}"
while IFS= read -r namespace; do
  [[ "$namespace" == "$PREFIX"* ]] || continue
  ip netns del "$namespace"
done < <(ip netns list | awk '{ print $1 }')

echo "Deleted network namespaces with prefix $PREFIX."
