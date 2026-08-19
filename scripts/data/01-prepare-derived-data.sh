#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

SIZES="${SIZES:-1m 10m 50m 100m}"
FRAMEWORKS="${FRAMEWORKS:-smartkg smartkg-plus wisekg passage spf ldf-endpoint ldf-tpf ldf-qpf ldf-brtpf ldf-dump-hdt}"
DELETE_PARTITION_NT="${DELETE_PARTITION_NT:-1}"
DATA_PREP_NODE_MB="${DATA_PREP_NODE_MB:-49152}"
DATA_PREP_JAVA_XMS="${DATA_PREP_JAVA_XMS:-8g}"
DATA_PREP_JAVA_XMX="${DATA_PREP_JAVA_XMX:-48g}"
GET_FAMILIES_NOFILE="${GET_FAMILIES_NOFILE:-131072}"
RDF2HDT="$SMARTKG_CREATOR_DIR/libhdt/tools/rdf2hdt"
GET_FAMILIES="$SMARTKG_CREATOR_DIR/libhdt/tools/getFamilies"
MAKE_CLASSES="$SMARTKG_CREATOR_DIR/make_filtered_classes.sh"

framework_enabled() {
  local expected="$1"
  for framework in $FRAMEWORKS; do
    if [[ "$framework" == "$expected" ]]; then
      return 0
    fi
  done
  return 1
}

only_passage_requested() {
  local framework
  for framework in $FRAMEWORKS; do
    if [[ "$framework" != "passage" ]]; then
      return 1
    fi
  done
  return 0
}

# Passage-only regeneration must not depend on the SmartKG partitioning tools.
if ! only_passage_requested; then
  require_file "$RDF2HDT"
  require_file "$GET_FAMILIES"
  require_file "$MAKE_CLASSES"
fi

prepare_get_families_limits() {
  local hard_limit
  hard_limit="$(ulimit -Hn)"
  if [[ "$hard_limit" != "unlimited" ]] && (( hard_limit < GET_FAMILIES_NOFILE )); then
    echo "getFamilies requires a nofile limit of at least $GET_FAMILIES_NOFILE; the hard limit is $hard_limit." >&2
    exit 1
  fi
  ulimit -Sn "$GET_FAMILIES_NOFILE"
  echo "getFamilies open-file limit: $(ulimit -Sn)."
}

convert_nt_dir_to_hdt() {
  local nt_dir="$1"
  local hdt_dir="$2"
  mkdir -p "$hdt_dir"
  find "$nt_dir" -maxdepth 1 -type f -name '*.nt' -print0 | while IFS= read -r -d '' nt_file; do
    local base
    base="$(basename "$nt_file" .nt)"
    local hdt_file="$hdt_dir/$base.hdt"
    local index_file="$hdt_file.index.v1-1"
    if [[ ! -f "$hdt_file" || ! -f "$index_file" || "${FORCE_HDT:-0}" == "1" ]]; then
      rm -f "$hdt_file" "$index_file"
      "$RDF2HDT" -i -f nt -B "http://watdiv.example/partition/" "$nt_file" "$hdt_file" \
        >> "$LOG_ROOT/partition-rdf2hdt.log" 2>&1
    fi
    require_file "$hdt_file"
    require_file "$index_file"
    if [[ "$DELETE_PARTITION_NT" == "1" ]]; then
      rm -f "$nt_file"
    fi
  done
}

normalize_partition_metadata_paths() {
  local metadata_file="$1"
  local nt_dir="$2"
  local hdt_dir="$3"

  if [[ ! -f "$metadata_file" ]]; then
    return
  fi

  METADATA_FILE="$metadata_file" NT_DIR="$nt_dir" HDT_DIR="$hdt_dir" node <<'NODE'
const fs = require('fs');
const metadataFile = process.env.METADATA_FILE;
const ntDir = process.env.NT_DIR.replace(/\/?$/u, '/');
const hdtDir = process.env.HDT_DIR.replace(/\/?$/u, '/');
const content = fs.readFileSync(metadataFile, 'utf8');
fs.writeFileSync(metadataFile, content.split(ntDir).join(hdtDir));
NODE
}

delete_partition_nt_after_conversion() {
  local metadata_file="$1"
  local nt_dir="$2"
  local hdt_dir="$3"

  if [[ "$DELETE_PARTITION_NT" != "1" ]]; then
    return
  fi
  require_file "$metadata_file"
  require_dir "$hdt_dir"
  if ! find "$hdt_dir" -maxdepth 1 -type f -name '*.hdt' -print -quit | grep -q .; then
    echo "No converted HDT partitions found in $hdt_dir; refusing to delete $nt_dir." >&2
    exit 1
  fi
  if grep -Fq "$nt_dir/" "$metadata_file"; then
    echo "Metadata still references NT partitions in $nt_dir; refusing to delete them." >&2
    exit 1
  fi
  node - "$metadata_file" <<'NODE'
const fs = require('fs');
const metadataFile = process.argv[2];
const metadata = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
if (!Array.isArray(metadata.families) || metadata.families.length === 0) {
  throw new Error(`No families found in ${metadataFile}`);
}
const byIndex = new Map(metadata.families.map(family => [ family.index, family ]));
const validated = new Set();
const visiting = new Set();
let materializedFamilies = 0;
let virtualFamilies = 0;

function validateFamily(family) {
  if (validated.has(family.index)) {
    return;
  }
  if (visiting.has(family.index)) {
    throw new Error(`Cyclic sourceSet detected at family ${family.index}`);
  }
  if (typeof family.name !== 'string' || !family.name.endsWith('.hdt')) {
    throw new Error(`Family ${family.index ?? '?'} does not reference an HDT file: ${family.name}`);
  }

  if (fs.existsSync(family.name)) {
    if (!fs.existsSync(`${family.name}.index.v1-1`)) {
      throw new Error(`Converted family index does not exist: ${family.name}.index.v1-1`);
    }
    materializedFamilies++;
    validated.add(family.index);
    return;
  }

  if (!Array.isArray(family.sourceSet) || family.sourceSet.length === 0) {
    throw new Error(`Family ${family.index} has no HDT file and no sourceSet: ${family.name}`);
  }

  visiting.add(family.index);
  for (const sourceIndex of family.sourceSet) {
    const sourceFamily = byIndex.get(sourceIndex);
    if (!sourceFamily) {
      throw new Error(`Family ${family.index} references unknown source family ${sourceIndex}`);
    }
    validateFamily(sourceFamily);
  }
  visiting.delete(family.index);
  virtualFamilies++;
  validated.add(family.index);
}

for (const family of metadata.families) {
  validateFamily(family);
}
console.log(`Validated ${materializedFamilies} materialized and ${virtualFamilies} virtual families.`);
NODE

  while IFS= read -r -d '' nt_file; do
    local base
    base="$(basename "$nt_file" .nt)"
    require_file "$hdt_dir/$base.hdt"
  done < <(find "$nt_dir" -maxdepth 1 -type f -name '*.nt' -print0)

  find "$nt_dir" -maxdepth 1 -type f -name '*.nt' -delete
  rmdir "$nt_dir"
  echo "Deleted verified NT intermediates from $nt_dir."
}

prepare_characteristic_sets() {
  local size="$1"
  local data_dir="$2"
  local cs_file="$data_dir/dataset.hdt.cs"

  if [[ -f "$cs_file" && "${FORCE_CS:-0}" != "1" ]]; then
    return
  fi

  NODE_OPTIONS="--max-old-space-size=$DATA_PREP_NODE_MB" DATASET_NT="$data_dir/dataset.nt" CS_FILE="$cs_file" node <<'NODE' \
    > "$LOG_ROOT/characteristic-sets-$size.log" 2>&1
const fs = require('fs');
const readline = require('readline');

const datasetNt = process.env.DATASET_NT;
const csFile = process.env.CS_FILE;
const subjects = new Map();

function parseTriple(line) {
  const match = /^(<[^>]+>|_:[^\s]+)\s+(<[^>]+>)\s+(.+)\s+\.\s*$/u.exec(line);
  if (!match) {
    return undefined;
  }
  return {
    subject: match[1].startsWith('<') ? match[1].slice(1, -1) : match[1],
    predicate: match[2].slice(1, -1),
    object: match[3],
  };
}

function getSubject(subject) {
  let entry = subjects.get(subject);
  if (!entry) {
    entry = new Map();
    subjects.set(subject, entry);
  }
  return entry;
}

(async() => {
  const rl = readline.createInterface({
    input: fs.createReadStream(datasetNt, { encoding: 'utf8' }),
    crlfDelay: Infinity,
  });

  let triples = 0;
  for await (const line of rl) {
    if (!line || line.startsWith('#')) {
      continue;
    }
    const triple = parseTriple(line);
    if (!triple) {
      continue;
    }
    const subject = getSubject(triple.subject);
    let predicate = subject.get(triple.predicate);
    if (!predicate) {
      predicate = { count: 0, objects: new Set() };
      subject.set(triple.predicate, predicate);
    }
    predicate.count++;
    predicate.objects.add(triple.object);
    triples++;
  }

  const characteristicSets = new Map();
  for (const predicateMap of subjects.values()) {
    const predicates = [...predicateMap.keys()].sort();
    const key = predicates.join('\u001F');
    let characteristicSet = characteristicSets.get(key);
    if (!characteristicSet) {
      characteristicSet = {
        distinct: 0,
        predicateMap: new Map(predicates.map(predicate => [predicate, { x: 0, objects: new Set() }])),
      };
      characteristicSets.set(key, characteristicSet);
    }
    characteristicSet.distinct++;
    for (const [predicate, stats] of predicateMap) {
      const aggregate = characteristicSet.predicateMap.get(predicate);
      aggregate.x += stats.count;
      for (const object of stats.objects) {
        aggregate.objects.add(object);
      }
    }
  }

  const out = fs.createWriteStream(csFile);
  for (const characteristicSet of characteristicSets.values()) {
    const predicateMap = {};
    for (const [predicate, stats] of characteristicSet.predicateMap) {
      predicateMap[predicate] = { x: stats.x, y: stats.objects.size };
    }
    out.write(`${JSON.stringify({ predicateMap, distinct: characteristicSet.distinct })}\n`);
  }
  out.end();
  await new Promise(resolve => out.on('finish', resolve));
  console.log(`Wrote ${characteristicSets.size} characteristic sets from ${subjects.size} subjects and ${triples} triples.`);
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
NODE
}

prepare_partitioning_with_tool() {
  local size="$1"
  local data_dir="$2"
  local part_dir="$3"
  local get_families="$4"
  local log_prefix="$5"
  local nt_dir="$part_dir/nt"
  local hdt_dir="$part_dir/hdt"
  mkdir -p "$nt_dir" "$hdt_dir"

  if [[ ! -f "$part_dir/metadata.json" || "${FORCE_PARTITIONING:-0}" == "1" ]]; then
    prepare_get_families_limits
    rm -f "$nt_dir"/*.nt "$part_dir"/metadata*.json
    if [[ "${FORCE_PARTITIONING:-0}" == "1" ]]; then
      rm -f "$hdt_dir"/*.hdt "$hdt_dir"/*.hdt.index.v1-1
    fi
    "$get_families" "$data_dir/dataset.hdt" \
      -s "$nt_dir/" \
      -e "$part_dir/metadata" \
      > "$LOG_ROOT/$log_prefix-$size.log" 2> "$LOG_ROOT/$log_prefix-$size.err"
  fi
  convert_nt_dir_to_hdt "$nt_dir" "$hdt_dir"
  normalize_partition_metadata_paths "$part_dir/metadata.json" "$nt_dir" "$hdt_dir"
  delete_partition_nt_after_conversion "$part_dir/metadata.json" "$nt_dir" "$hdt_dir"
}

prepare_partitioning() {
  local size="$1"
  local data_dir="$2"
  prepare_partitioning_with_tool "$size" "$data_dir" "$data_dir/partitioning" "$GET_FAMILIES" "getfamilies"
}

prepare_typed_partitioning_with_tool() {
  local size="$1"
  local data_dir="$2"
  local typed_dir="$3"
  local get_families="$4"
  local log_prefix="$5"
  local nt_dir="$typed_dir/nt"
  local hdt_dir="$typed_dir/hdt"
  mkdir -p "$nt_dir" "$hdt_dir"

  if [[ ! -f "$data_dir/classes.txt" || "${FORCE_CLASSES:-0}" == "1" ]]; then
    "$MAKE_CLASSES" "$data_dir/dataset.nt" "${CLASS_MIN_PERCENT:-0.001}" "${CLASS_MAX_PERCENT:-20}" "$data_dir/classes.txt" \
      > "$LOG_ROOT/classes-$size.log" 2>&1
  fi

  if [[ ! -f "$typed_dir/metadata.json" || "${FORCE_TYPED_PARTITIONING:-0}" == "1" ]]; then
    prepare_get_families_limits
    rm -f "$nt_dir"/*.nt "$typed_dir"/metadata*.json
    if [[ "${FORCE_TYPED_PARTITIONING:-0}" == "1" ]]; then
      rm -f "$hdt_dir"/*.hdt "$hdt_dir"/*.hdt.index.v1-1
    fi
    "$get_families" "$data_dir/dataset.hdt" \
      -s "$nt_dir/" \
      -e "$typed_dir/metadata" \
      -C "$data_dir/classes.txt" \
      > "$LOG_ROOT/$log_prefix-$size.log" 2> "$LOG_ROOT/$log_prefix-$size.err"
  fi
  convert_nt_dir_to_hdt "$nt_dir" "$hdt_dir"
  normalize_partition_metadata_paths "$typed_dir/metadata.json" "$nt_dir" "$hdt_dir"
  delete_partition_nt_after_conversion "$typed_dir/metadata.json" "$nt_dir" "$hdt_dir"
}

prepare_typed_partitioning() {
  local size="$1"
  local data_dir="$2"
  prepare_typed_partitioning_with_tool "$size" "$data_dir" "$data_dir/typed-partitioning" "$GET_FAMILIES" "getfamilies-typed"
}

prepare_passage() {
  local size="$1"
  local data_dir="$2"
  local passage_dir="$data_dir/passage"
  mkdir -p "$passage_dir"

  if [[ -f "$passage_dir/dataset.jnl" && "${FORCE_PASSAGE:-0}" != "1" ]]; then
    return
  fi

  local jar="$WORKSPACE_ROOT/passage-server/passage-cli/target/passage-server.jar"
  require_file "$jar"
  rm -f "$passage_dir/dataset.jnl"

  cat > "$passage_dir/local-data.properties" <<EOF
com.bigdata.journal.AbstractJournal.file=$passage_dir/dataset.jnl
# Passage is benchmarked over WatDiv's single default graph. Use Blazegraph's
# reclaiming read/write store and triple indexes; DiskWORM plus quad indexes
# produces a much larger journal without adding semantics needed here.
com.bigdata.journal.AbstractJournal.bufferMode=DiskRW
com.bigdata.rdf.store.AbstractTripleStore.quads=false
com.bigdata.rdf.store.AbstractTripleStore.statementIdentifiers=false
com.bigdata.rdf.store.AbstractTripleStore.textIndex=false
com.bigdata.rdf.store.AbstractTripleStore.axiomsClass=com.bigdata.rdf.axioms.NoAxioms
com.bigdata.rdf.sail.truthMaintenance=false
com.bigdata.rdf.store.AbstractTripleStore.justify=false
com.bigdata.namespace.kb.lex.com.bigdata.btree.BTree.branchingFactor=400
com.bigdata.namespace.kb.spo.com.bigdata.btree.BTree.branchingFactor=1024
EOF

  RIO_API="$(find "$HOME/.m2/repository/org/openrdf/sesame/sesame-rio-api" -name 'sesame-rio-api-*.jar' | sort -V | tail -1)"
  RIO_NTRIPLES="$(find "$HOME/.m2/repository/org/openrdf/sesame/sesame-rio-ntriples" -name 'sesame-rio-ntriples-*.jar' | sort -V | tail -1)"
  RIO_TURTLE="$(find "$HOME/.m2/repository/org/openrdf/sesame/sesame-rio-turtle" -name 'sesame-rio-turtle-*.jar' | sort -V | tail -1)"
  RIO_LANGUAGES="$(find "$HOME/.m2/repository/org/openrdf/sesame/sesame-rio-languages" -name 'sesame-rio-languages-*.jar' | sort -V | tail -1)"
  CP="$jar:$RIO_API:$RIO_NTRIPLES:$RIO_TURTLE:$RIO_LANGUAGES"

  java -Xms"$DATA_PREP_JAVA_XMS" -Xmx"$DATA_PREP_JAVA_XMX" -cp "$CP" com.bigdata.rdf.store.DataLoader \
    -defaultGraph "http://watdiv.example/$size/default" \
    "$passage_dir/local-data.properties" \
    "$data_dir/dataset.nt" \
    > "$LOG_ROOT/passage-load-$size.log" 2>&1
}

record_dataset_statistics() {
  local data_dir="$1"
  local manifest="$data_dir/manifest.json"
  require_file "$manifest"
  require_dir "$data_dir/partitioning/hdt"
  require_dir "$data_dir/typed-partitioning/hdt"

  local triples regular_partitions typed_partitions
  triples="$(wc -l < "$data_dir/dataset.nt" | tr -d ' ')"
  regular_partitions="$(find "$data_dir/partitioning/hdt" -maxdepth 1 -type f -name '*.hdt' | wc -l | tr -d ' ')"
  typed_partitions="$(find "$data_dir/typed-partitioning/hdt" -maxdepth 1 -type f -name '*.hdt' | wc -l | tr -d ' ')"

  node - "$manifest" "$triples" "$regular_partitions" "$typed_partitions" <<'NODE'
const fs = require('fs');
const [ manifestPath, triples, regularPartitions, typedPartitions ] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
manifest.triples = Number(triples);
manifest.regularPartitions = Number(regularPartitions);
manifest.typedPartitions = Number(typedPartitions);
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  echo "Dataset statistics: triples=$triples regularPartitions=$regular_partitions typedPartitions=$typed_partitions"
}

for size in $SIZES; do
  data_dir="$(size_dir "$size")"
  require_file "$data_dir/dataset.nt"
  if ! only_passage_requested; then
    require_file "$data_dir/dataset.hdt"
  fi

  if framework_enabled smartkg-plus || framework_enabled wisekg; then
    echo "==> Preparing characteristic sets for $size"
    prepare_characteristic_sets "$size" "$data_dir"
  fi

  if framework_enabled smartkg || framework_enabled wisekg; then
    echo "==> Preparing original SmartKG/WiseKG partitioning for $size"
    prepare_partitioning "$size" "$data_dir"
  fi

  if framework_enabled smartkg-plus; then
    echo "==> Preparing original SmartKG+ typed partitioning for $size"
    prepare_typed_partitioning "$size" "$data_dir"
  fi

  if framework_enabled passage; then
    echo "==> Preparing Passage Blazegraph journal for $size"
    prepare_passage "$size" "$data_dir"
  fi

  if ! only_passage_requested; then
    record_dataset_statistics "$data_dir"
  fi
done
