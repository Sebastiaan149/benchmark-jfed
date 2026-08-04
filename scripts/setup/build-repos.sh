#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

ROLE="${ROLE:-server}"

install_js_repo() {
  local repo="$1"
  echo "==> Installing JS dependencies for $repo"
  require_command yarn
  (cd "$WORKSPACE_ROOT/$repo" && yarn install --frozen-lockfile)
}

run_js_script() {
  local repo="$1"
  local script="$2"
  require_command yarn
  (cd "$WORKSPACE_ROOT/$repo" && yarn run "$script")
}

build_comunica() {
  install_js_repo comunicaMT
  run_js_script comunicaMT build:ts
  run_js_script comunicaMT build:components
}

case "$ROLE" in
  server)
    cd "$WORKSPACE_ROOT/smartKG-creator-types"
    if [[ ! -x libhdt/tools/rdf2hdt || ! -x libhdt/tools/getFamilies ]]; then
      ./gnulib.sh
      ./autogen.sh
      ./configure
      make -j"$(nproc)"
    fi

    for repo in original-smartkg-server smartkg_plus_server spf-server wisekg-server passage-server; do
      echo "==> Building $repo"
      (cd "$WORKSPACE_ROOT/$repo" && mvn -DskipTests clean package)
    done

    for repo in Server.js jbr.js passage-comunica; do
      install_js_repo "$repo"
    done
    build_comunica
    ;;
  client)
    build_comunica
    echo "==> Installing the dedicated Comunica HDT client"
    (cd "$BENCHMARK_DIR" && npm ci --omit=dev --no-audit --no-fund)
    ;;
  *)
    echo "Usage: ROLE=server|client $0" >&2
    exit 1
    ;;
esac
