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

# -- host resource monitor -------------------------------------------------
# How to collect host stats (CPU/GPU/mem/disk/net): "auto" runs locally when the
# dashboard is on the LXD host (real snap socket present), else SSH to LXD_HOST.
HOST_STATS = os.environ.get("HOST_STATS", "auto")  # auto | local | ssh | off
LXD_HOST = os.environ.get("LXD_HOST")              # ssh target for dev/remote


def host_is_local() -> bool:
    """True if the real on-host LXD socket is in use (so /proc + nvidia-smi are local)."""
    return os.path.exists("/var/snap/lxd/common/lxd/unix.socket")


# -- VM LAN SSH credentials (shown in the dashboard Access card) -----------
LAB_VM_USER = os.environ.get("LAB_VM_USER", "lab")
LAB_VM_PASSWORD = os.environ.get("LAB_VM_PASSWORD", "")  # set in gitignored .env
