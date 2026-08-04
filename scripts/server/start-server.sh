#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/lib.sh
source "$SCRIPT_DIR/../shared/lib.sh"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <framework> <size>" >&2
  exit 1
fi

FRAMEWORK="$1"
SIZE="$2"
DATA_DIR_FOR_SIZE="$(size_dir "$SIZE")"
PORT="${PORT:-$(framework_port "$FRAMEWORK")}"
SERVER_KIND="$(framework_server "$FRAMEWORK")"
WORKERS="${WORKERS:-$(node_json 'c.resources.workers')}"
QUERY_TIMEOUT_SECONDS="${QUERY_TIMEOUT_SECONDS:-$(node_json 'c.resources.queryTimeoutSeconds')}"
CONFIG_OUT="$TMP_ROOT/configs/$SIZE"
mkdir -p "$CONFIG_OUT"

SMARTKG_PARTITIONING_DIR="partitioning"
SMARTKG_TYPED_PARTITIONING_DIR="typed-partitioning"

require_dir "$DATA_DIR_FOR_SIZE"

check_framework_requirements() {
  node - "$CONFIG_FILE" "$FRAMEWORK" "$DATA_DIR_FOR_SIZE" <<'NODE'
const fs = require('fs');
const path = require('path');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const framework = config.frameworks[process.argv[3]];
const dataDir = process.argv[4];
if (!framework) {
  console.error(`Unknown framework: ${process.argv[3]}`);
  process.exit(1);
}
for (const rel of framework.requires || []) {
  const target = path.join(dataDir, rel);
  if (!fs.existsSync(target)) {
    console.error(`Missing required ${rel} for ${process.argv[3]} at ${target}`);
    process.exit(1);
  }
}
NODE
}

write_java_config() {
  local name="$1"
  local datasource="$2"
  local metadata_path="$3"
  local molecules_path="$4"
  local dataset_file="$5"
  local cspath="${6:-}"
  local output="$7"
  node - "$name" "$datasource" "$metadata_path" "$molecules_path" "$dataset_file" "$cspath" "$output" "$PORT" "${SERVER_IP:-localhost}" <<'NODE'
const fs = require('fs');
const [ name, datasource, metadataPath, moleculesPath, datasetFile, csPath, output, port, serverHost ] = process.argv.slice(2);
const config = {
  title: `${name} WatDiv server`,
  metadatapath: metadataPath,
  moleculesdatapath: moleculesPath,
  datasourcetypes: {
    HdtDatasource: 'org.linkeddatafragments.datasource.hdt.HdtDataSourceType',
    JenaTDBDatasource: 'org.linkeddatafragments.datasource.tdb.JenaTDBDataSourceType',
  },
  datasources: {
    [datasource]: {
      title: datasource,
      type: 'HdtDatasource',
      description: `${name} WatDiv dataset`,
      settings: { file: datasetFile },
    },
  },
  prefixes: {
    rdf: 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
    rdfs: 'http://www.w3.org/2000/01/rdf-schema#',
    xsd: 'http://www.w3.org/2001/XMLSchema#',
    foaf: 'http://xmlns.com/foaf/0.1/',
    schema: 'http://schema.org/',
    wsdbm: 'http://db.uwaterloo.ca/~galuc/wsdbm/',
    gr: 'http://purl.org/goodrelations/',
    rev: 'http://purl.org/stuff/rev#',
    ogp: 'http://ogp.me/ns#',
    hydra: 'http://www.w3.org/ns/hydra/core#',
    void: 'http://rdfs.org/ns/void#',
  },
};
if (csPath) {
  config.cspath = csPath;
  config.partstring = '';
  config.default = datasource;
  config.uri = `http://${serverHost}:${port}/`;
}
if (datasource === 'smartkg') {
  config.datasources[datasource].serverType = 'original-smartkg';
}
fs.writeFileSync(output, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

write_spf_config() {
  local output="$1"
  node - "$DATA_DIR_FOR_SIZE/dataset.hdt" "$output" <<'NODE'
const fs = require('fs');
const [ datasetFile, output ] = process.argv.slice(2);
fs.writeFileSync(output, `${JSON.stringify({
  title: 'WatDiv SPF server',
  datasourcetypes: {
    HdtDatasource: 'org.linkeddatafragments.datasource.hdt.HdtDataSourceType',
  },
  datasources: {
    spf: {
      title: 'spf',
      type: 'HdtDatasource',
      description: 'WatDiv SPF dataset',
      settings: { file: datasetFile },
    },
  },
  prefixes: {
    rdf: 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
    rdfs: 'http://www.w3.org/2000/01/rdf-schema#',
    xsd: 'http://www.w3.org/2001/XMLSchema#',
    foaf: 'http://xmlns.com/foaf/0.1/',
    schema: 'http://schema.org/',
    wsdbm: 'http://db.uwaterloo.ca/~galuc/wsdbm/',
    gr: 'http://purl.org/goodrelations/',
    rev: 'http://purl.org/stuff/rev#',
    ogp: 'http://ogp.me/ns#',
    hydra: 'http://www.w3.org/ns/hydra/core#',
    void: 'http://rdfs.org/ns/void#',
  },
}, null, 2)}\n`);
NODE
}

write_ldf_config() {
  local mode="$1"
  local output="$2"
  node - "$mode" "$DATA_DIR_FOR_SIZE/dataset.hdt" "$output" <<'NODE'
const fs = require('fs');
const [ mode, hdtFile, output ] = process.argv.slice(2);
const path = 'watdiv';
const config = {
  '@context': 'https://linkedsoftwaredependencies.org/bundles/npm/@ldf/server/^3.0.0/components/context.jsonld',
  '@id': 'urn:ldf-server:my',
  import: 'preset-qpf:config-defaults.json',
  title: `WatDiv ${mode.toUpperCase()} server`,
  datasources: [{
    '@id': 'urn:ldf-server:myHdtDatasource',
    '@type': 'HdtDatasource',
    datasourceTitle: `WatDiv ${mode.toUpperCase()}`,
    description: `WatDiv ${mode.toUpperCase()} over HDT`,
    datasourcePath: path,
    hdtFile,
  }],
  prefixes: [
    { prefix: 'rdf', uri: 'http://www.w3.org/1999/02/22-rdf-syntax-ns#' },
    { prefix: 'rdfs', uri: 'http://www.w3.org/2000/01/rdf-schema#' },
    { prefix: 'xsd', uri: 'http://www.w3.org/2001/XMLSchema#' },
    { prefix: 'foaf', uri: 'http://xmlns.com/foaf/0.1/' },
    { prefix: 'schema', uri: 'http://schema.org/' },
    { prefix: 'wsdbm', uri: 'http://db.uwaterloo.ca/~galuc/wsdbm/' },
    { prefix: 'gr', uri: 'http://purl.org/goodrelations/' },
    { prefix: 'rev', uri: 'http://purl.org/stuff/rev#' },
    { prefix: 'ogp', uri: 'http://ogp.me/ns#' },
    { prefix: 'hydra', uri: 'http://www.w3.org/ns/hydra/core#' },
    { prefix: 'void', uri: 'http://rdfs.org/ns/void#' },
  ],
};
fs.writeFileSync(output, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

write_passage_config() {
  local output="$1"
  node - "$DATA_DIR_FOR_SIZE/passage/local-data.properties" "$output" <<'NODE'
const fs = require('fs');
const [ properties, output ] = process.argv.slice(2);
fs.writeFileSync(output, `
PREFIX :        <#>
PREFIX fuseki:  <http://jena.apache.org/fuseki#>
PREFIX rdf:     <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX owl:     <http://www.w3.org/2002/07/owl#>
PREFIX psg:     <http://fr.gdd.passage/engine-vocabulary#>
PREFIX sd:      <http://www.w3.org/ns/sparql-service-description#>

[] rdf:type fuseki:Server ;
   fuseki:services ( :service_data_passage :service_data_raw :service_data_sparql ) .

:service_data_passage rdf:type fuseki:Service ;
    fuseki:name "data/passage" ;
    fuseki:endpoint [ fuseki:operation psg:query_w_args ] ;
    fuseki:dataset :dataset_data_passage .

:service_data_raw rdf:type fuseki:Service ;
    fuseki:name "data/raw" ;
    fuseki:endpoint [ fuseki:operation psg:query_w_args ] ;
    fuseki:dataset :dataset_data_raw .

:service_data_sparql rdf:type fuseki:Service ;
    fuseki:name "data/sparql" ;
    fuseki:endpoint [ fuseki:operation psg:query_w_args ] ;
    fuseki:dataset :dataset_data_sparql .

:dataset_data_passage rdf:type psg:DatasetBlazegraph ;
    psg:location "${properties}" ;
    psg:timeout 10000 ;
    psg:max_results 10000 ;
    psg:engine psg:PassageEngine ;
    psg:description :data_description .

:dataset_data_raw rdf:type psg:DatasetBlazegraph ;
    psg:location "${properties}" ;
    psg:timeout 10000 ;
    psg:max_results 10000 ;
    psg:engine psg:RawEngine .

:dataset_data_sparql rdf:type psg:DatasetBlazegraph ;
    psg:location "${properties}" ;
    psg:timeout 60000 ;
    psg:engine psg:SPARQLEngine .

:data_description rdf:type sd:Service ;
    sd:endpoint "data/passage" ;
    sd:supportedLanguage :passage-0.2.0 .

:passage-0.2.0 owl:sameAs :passage-0.0.3 .
:passage-0.0.3 rdf:type sd:Language ;
    psg:support psg:project, psg:values, psg:union, psg:join, psg:bgp, psg:pattern, psg:extend, psg:filter, psg:optional .
`);
NODE
}

check_framework_requirements
export NODE_OPTIONS="${NODE_OPTIONS:-$(node_options)}"

case "$SERVER_KIND" in
  original-smartkg-server)
    cfg="$CONFIG_OUT/smartkg.json"
    write_java_config "SmartKG" "smartkg" "$DATA_DIR_FOR_SIZE/$SMARTKG_PARTITIONING_DIR/metadata.json" "$DATA_DIR_FOR_SIZE/$SMARTKG_PARTITIONING_DIR/hdt" "$DATA_DIR_FOR_SIZE/dataset.hdt" "" "$cfg"
    cd "$WORKSPACE_ROOT/original-smartkg-server"
    exec java $(java_opts) -jar target/ldf-server.jar "$cfg" -p "$PORT"
    ;;
  smartkg_plus_server)
    cfg="$CONFIG_OUT/smartkg-plus.json"
    write_java_config "SmartKG+" "smartkg+" "$DATA_DIR_FOR_SIZE/$SMARTKG_TYPED_PARTITIONING_DIR/metadata.json" "$DATA_DIR_FOR_SIZE/$SMARTKG_TYPED_PARTITIONING_DIR/hdt" "$DATA_DIR_FOR_SIZE/dataset.hdt" "$DATA_DIR_FOR_SIZE/dataset.hdt.cs" "$cfg"
    cd "$WORKSPACE_ROOT/smartkg_plus_server"
    exec java $(java_opts) -jar target/ldf-server.jar "$cfg" -p "$PORT"
    ;;
  wisekg-server)
    cfg="$CONFIG_OUT/wisekg.json"
    write_java_config "WiseKG" "wisekg" "$DATA_DIR_FOR_SIZE/partitioning/metadata.json" "$DATA_DIR_FOR_SIZE/partitioning/hdt" "$DATA_DIR_FOR_SIZE/dataset.hdt" "$DATA_DIR_FOR_SIZE/dataset.hdt.cs" "$cfg"
    cd "$WORKSPACE_ROOT/wisekg-server"
    exec java $(java_opts) -jar target/ldf-server.jar "$cfg" -p "$PORT"
    ;;
  spf-server)
    cfg="$CONFIG_OUT/spf.json"
    write_spf_config "$cfg"
    cd "$WORKSPACE_ROOT/spf-server"
    exec java $(java_opts) -jar target/ldf-server.jar "$cfg" -p "$PORT"
    ;;
  passage-server)
    cfg="$CONFIG_OUT/passage.ttl"
    write_passage_config "$cfg"
    cd "$WORKSPACE_ROOT/passage-server"
    exec java $(java_opts) -jar passage-cli/target/passage-server.jar --port "$PORT" --ping --stats --config="$cfg"
    ;;
  comunica-file-http)
    cd "$COMUNICA_DIR"
    exec node engines/query-sparql-file/bin/http.js --port "$PORT" --workers "$WORKERS" --timeout "$QUERY_TIMEOUT_SECONDS" "$DATA_DIR_FOR_SIZE/dataset.nt"
    ;;
  server-js-tpf)
    cfg="$CONFIG_OUT/ldf-tpf.json"
    write_ldf_config "tpf" "$cfg"
    cd "$WORKSPACE_ROOT/Server.js"
    export NODE_PATH="$COMUNICA_DIR/node_modules${NODE_PATH:+:$NODE_PATH}"
    exec node packages/server/bin/ldf-server "$cfg" "$PORT" "$WORKERS"
    ;;
  server-js-qpf)
    cfg="$CONFIG_OUT/ldf-qpf.json"
    write_ldf_config "qpf" "$cfg"
    cd "$WORKSPACE_ROOT/Server.js"
    export NODE_PATH="$COMUNICA_DIR/node_modules${NODE_PATH:+:$NODE_PATH}"
    exec node packages/server/bin/ldf-server "$cfg" "$PORT" "$WORKERS"
    ;;
  static-hdt-dump)
    exec node "$SCRIPT_DIR/static-dataset-server.js" "$DATA_DIR_FOR_SIZE" "$PORT"
    ;;
  unsupported)
    node -e "const fs=require('fs'); const c=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); console.error(c.frameworks[process.argv[2]].unsupportedReason)" "$CONFIG_FILE" "$FRAMEWORK"
    exit 2
    ;;
  *)
    echo "Unsupported server kind: $SERVER_KIND" >&2
    exit 1
    ;;
esac
