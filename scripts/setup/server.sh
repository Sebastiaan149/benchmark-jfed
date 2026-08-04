#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROLE=server "$SCRIPT_DIR/install-deps.sh"
ROLE=server "$SCRIPT_DIR/clone-repos.sh"
ROLE=server "$SCRIPT_DIR/build-repos.sh"
