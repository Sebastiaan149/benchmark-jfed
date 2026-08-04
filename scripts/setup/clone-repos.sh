#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
source "$SCRIPT_DIR/../shared/common.sh"

ROLE="${ROLE:-server}"

mkdir -p "$WORKSPACE_ROOT"
cd "$WORKSPACE_ROOT"

clone_or_update() {
  local dir="$1"
  local url="$2"
  if [[ -d "$dir/.git" ]]; then
    echo "==> Updating $dir"
    git -C "$dir" fetch --all --tags
    git -C "$dir" pull --ff-only
  else
    echo "==> Cloning $dir"
    git clone "$url" "$dir"
  fi
}

clone_or_update comunicaMT https://github.com/Sebastiaan149/comunicaMT.git

case "$ROLE" in
  server)
    clone_or_update Server.js https://github.com/LinkedDataFragments/Server.js.git
    clone_or_update jbr.js https://github.com/rubensworks/jbr.js.git
    clone_or_update original-smartkg-server https://github.com/Sebastiaan149/original-smartkg-server.git
    clone_or_update smartKG-creator-types https://github.com/Sebastiaan149/smartKG-creator-types.git
    clone_or_update smartkg_plus_server https://github.com/Sebastiaan149/smartkg_plus_server.git
    clone_or_update spf-server https://github.com/Sebastiaan149/spf-server.git
    clone_or_update wisekg-server https://github.com/Sebastiaan149/wisekg-server.git
    clone_or_update passage-server https://github.com/Sebastiaan149/passage-server.git
    clone_or_update passage-comunica https://github.com/passage-org/passage-comunica.git
    ;;
  client)
    ;;
  *)
    echo "Usage: ROLE=server|client $0" >&2
    exit 1
    ;;
esac

echo "$ROLE repos are present under $WORKSPACE_ROOT."
