"""Runtime configuration resolved from environment variables."""

import os

# Candidate socket paths, in priority order.
#  1. Explicit LXD_SOCKET override.
#  2. The real LXD socket (when running on the LXD host).
#  3. An SSH-forwarded socket on the dev laptop (see README / forward-socket.sh).
_CANDIDATES = [
    os.environ.get("LXD_SOCKET"),
    "/var/snap/lxd/common/lxd/unix.socket",
    os.path.expanduser("~/.lxd.socket"),
    "/tmp/lxd.socket",
]

DEFAULT_SOCKET = "/var/snap/lxd/common/lxd/unix.socket"


def resolve_socket() -> str:
    """Return the first socket path that exists, else the configured/default path."""
    for path in _CANDIDATES:
        if path and os.path.exists(path):
            return path
    return os.environ.get("LXD_SOCKET") or DEFAULT_SOCKET


HOST = os.environ.get("AK_LXD_HOST", "127.0.0.1")
PORT = int(os.environ.get("AK_LXD_PORT", "8080"))
