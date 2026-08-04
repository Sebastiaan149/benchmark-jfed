#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROLE=client "$SCRIPT_DIR/install-deps.sh"
ROLE=client "$SCRIPT_DIR/clone-repos.sh"
ROLE=client "$SCRIPT_DIR/build-repos.sh"
