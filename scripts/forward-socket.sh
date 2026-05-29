#!/usr/bin/env bash
# Forward the LXD Unix socket from the LXD host to this machine over SSH, so the
# dashboard can run locally during development. Reads LXD_HOST / LXD_SOCKET /
# LXD_REMOTE_SOCKET from .env (or the environment).
#
#   scripts/forward-socket.sh        # runs in the foreground; Ctrl-C to stop
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a; # shellcheck disable=SC1091
  . "$ROOT/.env"; set +a
fi

HOST="${LXD_HOST:?Set LXD_HOST in .env (copy .env.example)}"
LOCAL_SOCK="${LXD_SOCKET:-$HOME/.lxd.socket}"
REMOTE_SOCK="${LXD_REMOTE_SOCKET:-/var/snap/lxd/common/lxd/unix.socket}"

rm -f "$LOCAL_SOCK"
echo "Forwarding ${HOST}:${REMOTE_SOCK}  ->  ${LOCAL_SOCK}"
echo "Leave this running; start the dashboard in another terminal."
exec ssh -nNT -o ServerAliveInterval=15 -L "${LOCAL_SOCK}:${REMOTE_SOCK}" "$HOST"
