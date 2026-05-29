#!/usr/bin/env bash
# Quick raw access to the LXD REST API over the Unix socket, for debugging.
#
#   scripts/lxc-api.sh GET /1.0
#   scripts/lxc-api.sh GET /1.0/instances?recursion=2
#   scripts/lxc-api.sh POST /1.0/instances/foo/state '{"action":"start"}'
#
# Honors $LXD_SOCKET; otherwise tries the on-host socket then an SSH-forwarded one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  . "$ROOT/.env"; set +a
fi

socket="${LXD_SOCKET:-}"
if [[ -z "$socket" ]]; then
  for c in /var/snap/lxd/common/lxd/unix.socket "$HOME/.lxd.socket" /tmp/lxd.socket; do
    [[ -S "$c" ]] && { socket="$c"; break; }
  done
fi
[[ -z "$socket" ]] && { echo "No LXD socket found. Set LXD_SOCKET." >&2; exit 1; }

method="${1:-GET}"
path="${2:-/1.0}"
data="${3:-}"

args=(-s --unix-socket "$socket" -X "$method" "http://lxd${path}")
[[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

if command -v jq >/dev/null 2>&1; then
  curl "${args[@]}" | jq
else
  curl "${args[@]}"
  echo
fi
