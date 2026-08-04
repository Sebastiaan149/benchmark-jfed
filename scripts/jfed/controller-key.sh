#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../config/cluster.env
source "$SCRIPT_DIR/../../config/cluster.env"

ACTION="${1:-}"
case "$ACTION" in
  generate)
    mkdir -p "$HOME/.ssh"
    if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
      ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
    fi
    public_key="$(cat "$HOME/.ssh/id_ed25519.pub")"
    [[ "$public_key" == ssh-ed25519\ * ]] || { echo "Could not create an Ed25519 key." >&2; exit 1; }
    printf 'mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && { grep -qxF %q ~/.ssh/authorized_keys || echo %q >> ~/.ssh/authorized_keys; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys\n' \
      "$public_key" "$public_key"
    ;;
  verify)
    targets=("$SERVER_SSH")
    read -r -a remote_clients <<< "$CLIENT_SSHS"
    targets+=("${remote_clients[@]}")
    for target in "${targets[@]}"; do
      host="${target#*@}"
      ssh-keygen -R "$host" >/dev/null 2>&1 || true
      ssh-keyscan -H "$host" >> "$HOME/.ssh/known_hosts" 2>/dev/null
      ssh -o BatchMode=yes "$target" 'hostname; sudo -n true'
    done
    echo "Controller SSH access verified."
    ;;
  *)
    echo "Usage: $0 generate|verify" >&2
    exit 1
    ;;
esac
