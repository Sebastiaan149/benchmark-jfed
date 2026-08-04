#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

PROFILE="${1:-}"
case "$PROFILE" in
  smoke-1m)
    sizes=("1m")
    ;;
  full)
    sizes=("1m" "10m" "50m" "100m")
    ;;
  *)
    echo "Usage: $0 smoke-1m|full" >&2
    exit 1
    ;;
esac

frameworks="smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt"
for size in "${sizes[@]}"; do
  echo "==> Preparing $size on server0"
  ssh -o BatchMode=yes "$SERVER_SSH" \
    "cd '$REMOTE_WORKSPACE' && SIZES='$size' FRAMEWORKS='$frameworks' DELETE_PARTITION_NT=1 DATA_PREP_NODE_MB=49152 DATA_PREP_JAVA_XMS=8g DATA_PREP_JAVA_XMX=48g ./benchmark-jfed/scripts/data/generate-and-prepare.sh"
  ssh -o BatchMode=yes "$SERVER_SSH" \
    "cd '$REMOTE_WORKSPACE' && ./benchmark-jfed/scripts/data/storage-report.sh"
done

echo "Data preparation profile $PROFILE complete."
