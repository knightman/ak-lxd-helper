"""Host resource stats (CPU/GPU/memory/disk/network).

LXD's API exposes per-*instance* metrics but not host CPU/GPU, so we collect them
from the host directly: `/proc` + `nvidia-smi`. The collector runs locally when the
dashboard is on the LXD host, or over SSH to ``LXD_HOST`` otherwise. Non-blocking
(asyncio subprocess); degrades to ``{"available": False}`` when it can't run.
"""

from __future__ import annotations

import asyncio
import json

from . import config

# Emitted on the host's stdin and run by its python3. Stdlib only; samples
# /proc/stat twice for a CPU%, reads mem/net/disk, and queries nvidia-smi.
_SCRIPT = r"""
import json, time, os, subprocess, shutil

def cpu_sample():
    with open('/proc/stat') as f:
        for line in f:
            if line.startswith('cpu '):
                p = [int(x) for x in line.split()[1:]]
                idle = p[3] + (p[4] if len(p) > 4 else 0)
                return idle, sum(p)
    return 0, 0

i1, t1 = cpu_sample(); time.sleep(0.25); i2, t2 = cpu_sample()
dt, di = t2 - t1, i2 - i1
cpu_pct = round(100 * (1 - di / dt), 1) if dt > 0 else None

mem = {}
with open('/proc/meminfo') as f:
    for line in f:
        k, _, v = line.partition(':')
        mem[k] = int(v.strip().split()[0]) * 1024
mem_total = mem.get('MemTotal', 0)
mem_used = mem_total - mem.get('MemAvailable', 0)

net = {}
with open('/proc/net/dev') as f:
    for line in f.readlines()[2:]:
        name, _, rest = line.partition(':')
        name = name.strip()
        if name == 'lo':
            continue
        c = rest.split()
        net[name] = {'rx': int(c[0]), 'tx': int(c[8])}

du = shutil.disk_usage('/')
disk = {'total': du.total, 'used': du.used, 'free': du.free}

gpus = []
if shutil.which('nvidia-smi'):
    try:
        out = subprocess.run(
            ['nvidia-smi',
             '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu',
             '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=6).stdout
        for line in out.strip().splitlines():
            cols = [c.strip() for c in line.split(',')]
            def num(x):
                try: return float(x)
                except Exception: return None
            gpus.append({'name': cols[0], 'util': num(cols[1]),
                         'mem_used': num(cols[2]), 'mem_total': num(cols[3]),
                         'temp': num(cols[4])})
    except Exception:
        pass

print(json.dumps({'available': True, 'cpu_pct': cpu_pct, 'ncpu': os.cpu_count(),
                  'load': list(os.getloadavg()), 'mem_total': mem_total,
                  'mem_used': mem_used, 'net': net, 'disk': disk, 'gpus': gpus,
                  'ts': time.time()}))
"""


def _mode() -> str | None:
    m = config.HOST_STATS
    if m == "off":
        return None
    if m in ("local", "ssh"):
        return m
    # auto
    if config.host_is_local():
        return "local"
    return "ssh" if config.LXD_HOST else None


async def host_stats() -> dict:
    mode = _mode()
    if mode is None:
        return {"available": False, "reason": "host stats disabled or no host access (set LXD_HOST)"}
    if mode == "local":
        cmd = ["python3", "-"]
    else:
        if not config.LXD_HOST:
            return {"available": False, "reason": "LXD_HOST not set"}
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", config.LXD_HOST, "python3", "-"]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(_SCRIPT.encode()), timeout=15)
        if proc.returncode != 0:
            return {"available": False, "reason": (err.decode(errors="replace")[:300] or "stats command failed")}
        return json.loads(out.decode())
    except (asyncio.TimeoutError, OSError, ValueError) as e:
        return {"available": False, "reason": str(e)}
