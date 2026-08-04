#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"
QUERY_COUNT="${QUERY_COUNT:-$(node_json 'c.queryCount')}"
QUERY_RECURRENCE="${QUERY_RECURRENCE:-$(node_json 'c.queryRecurrence')}"
WATDIV_IMAGE="${WATDIV_IMAGE:-comunica/watdiv@sha256:2fac67737d6dddd75ea023b90bba2a1c7432a00e233791a802e374e3d2a8ec3b}"
RDF2HDT="$SMARTKG_CREATOR_DIR/libhdt/tools/rdf2hdt"

require_command docker
require_file "$RDF2HDT"
docker info >/dev/null

for size in $SIZES; do
  out_dir="$(size_dir "$size")"
  scale="$(node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.log(c.sizes[process.argv[2]].scale)" "$CONFIG_FILE" "$size")"
  mkdir -p "$out_dir"

  if [[ -f "$out_dir/dataset.nt" && -d "$out_dir/queries" && "${FORCE_DATA:-0}" != "1" ]]; then
    echo "==> Reusing existing WatDiv $size dataset"
  else
    echo "==> Generating WatDiv $size (scale=$scale, queryCount=$QUERY_COUNT, recurrence=$QUERY_RECURRENCE)"
    docker run --rm \
      -v "$out_dir:/output" \
      "$WATDIV_IMAGE" \
      -s "$scale" \
      -q "$QUERY_COUNT" \
      -r "$QUERY_RECURRENCE" \
      > "$LOG_ROOT/watdiv-generate-$size.log" 2>&1
  fi

  require_file "$out_dir/dataset.nt"
  require_dir "$out_dir/queries"

  if [[ ! -f "$out_dir/dataset.hdt" || "${FORCE_HDT:-0}" == "1" ]]; then
    echo "==> Converting $size dataset.nt to indexed HDT"
    "$RDF2HDT" -i -f nt -B "http://watdiv.example/$size/" "$out_dir/dataset.nt" "$out_dir/dataset.hdt" \
      > "$LOG_ROOT/rdf2hdt-$size.log" 2>&1
  fi

  cat > "$out_dir/manifest.json" <<EOF
{
  "size": "$size",
  "scale": "$scale",
  "queryCount": $QUERY_COUNT,
  "queryRecurrence": $QUERY_RECURRENCE,
  "datasetNt": "dataset.nt",
  "datasetHdt": "dataset.hdt",
  "queries": "queries"
}
EOF
done
