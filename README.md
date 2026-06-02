# ak-lxd-helper

A lightweight, agentic web dashboard for managing an [LXD](https://canonical.com/lxd)
host. It talks to LXD's REST API **directly over the local Unix socket** — no TLS,
no certificates, no `lxc remote add`.

The goal: do the common LXD chores from a point-and-click dashboard (and a small
JSON API) so you don't have to keep the LXD docs open.

> Host-specific values (hostname, socket path, port) live in a gitignored `.env`.
> Copy `.env.example` to `.env` and adjust. Nothing in the committed tree hardcodes
> a particular machine.

---

## What it can do

| Area | Features |
|------|----------|
| **Host monitor** | Live host CPU%, memory, **GPU** (nvidia-smi), disk, network on the Dashboard, plus per-instance CPU/mem/net (auto-refresh) |
| **Logs** | Per-instance host-side LXD logs (`qemu.log`) + quick in-guest `journalctl`/`cloud-init`/`syslog` |
| **LAN access** | Give VMs a real LAN IP (macvlan) + password SSH; dashboard shows IP + credentials + `ssh` command |
| **Instances** | List with status/IP/memory; create container, VM, or **empty VM**; start / stop / restart / freeze; edit config (`limits.cpu`, `limits.memory`, profiles, description); snapshots (create/restore/delete); rename; delete |
| **Run commands** | One-off non-interactive `exec` with captured stdout/stderr/exit code |
| **Terminal** | Full interactive shell inside an instance (xterm.js over a WebSocket proxy) |
| **Console** | Attach to an instance's serial console (boot messages, installer, login) |
| **Images** | List local images; import (pull) from a remote simplestreams/lxd server; add aliases; edit properties; delete |
| **Storage & ISOs** | List pools/volumes; **upload an ISO as a custom volume**; delete volumes |
| **Devices** | Attach/detach instance devices (e.g. a bootable ISO disk) |

Everything is driven by the LXD REST API; the only state the app keeps is the
socket path.

---

## Architecture

```
browser (dashboard, xterm.js)
      │  HTTP /api/*  +  WebSocket /ws/*
      ▼
aiohttp server  (src/aklxd/server.py)
      │  HTTP + WebSocket over the LXD Unix socket
      ▼
LXD REST API  (/var/snap/lxd/common/lxd/unix.socket)
```

- **`src/aklxd/lxd.py`** — async LXD client. Wraps the REST API, waits on LXD's
  background *operations*, and exposes high-level methods (instances, images,
  exec, console, storage/ISO upload, devices).
- **`src/aklxd/server.py`** — aiohttp app. Serves the dashboard, exposes a JSON
  API under `/api`, and **proxies WebSockets** for interactive exec/console
  (`/ws/exec/{name}`, `/ws/console/{name}`).
- **`web/`** — single-page dashboard (vanilla JS + xterm.js from a CDN).
- **`bin/ak-lxd-helper`** — launcher; sources `.env`, creates/activates the conda
  env, runs the server.
- **`scripts/forward-socket.sh`** — SSH-forward the LXD socket to a dev machine.
- **`scripts/lxc-api.sh`** — `curl` wrapper for poking the raw API while debugging.

Why aiohttp? LXD's interactive `exec` and `console` are WebSocket streams, and
aiohttp can both connect to a Unix-socket WebSocket *and* serve one to the
browser — so it bridges the two cleanly.

---

## Requirements

- [conda](https://docs.conda.io/) (Miniconda/Anaconda). The launcher builds the
  env on first run from `environment.yml` (Python 3.12 + aiohttp).
- Access to an LXD Unix socket — either locally (running on the LXD host) or
  forwarded over SSH (see below).

---

## Quick start

```bash
git clone <this repo> ak-lxd-helper && cd ak-lxd-helper
cp .env.example .env        # then edit LXD_HOST etc.
```

### Run on the LXD host

```bash
bin/ak-lxd-helper                       # first run creates the conda env
```

Open **http://localhost:8080**. To reach it from another machine on the LAN, bind
to all interfaces:

```bash
bin/ak-lxd-helper --host 0.0.0.0 --port 8080
```

> Your user must be able to read the LXD socket (be in the `lxd` group, or run as
> root). Test with: `scripts/lxc-api.sh GET /1.0`.

### Local development (SSH-forwarded socket)

If the LXD socket lives on another machine, forward it over SSH. Set `LXD_HOST`
in `.env`, then:

```bash
scripts/forward-socket.sh        # leave running; forwards to $LXD_SOCKET (default ~/.lxd.socket)
```

In another terminal:

```bash
bin/ak-lxd-helper                # auto-detects the forwarded socket
# open http://localhost:8080
```

> The remote SSH user must be able to read `/var/snap/lxd/common/lxd/unix.socket`
> (be in the `lxd` group on the host).

---

## Configuration

CLI flags > environment variables > `.env` > defaults. The launcher and scripts
source `.env` automatically.

| Setting | Env var | Flag | Default |
|---------|---------|------|---------|
| LXD socket path | `LXD_SOCKET` | `--socket` | auto-detected¹ |
| Dashboard bind host | `AK_LXD_HOST` | `--host` | `127.0.0.1` |
| Dashboard bind port | `AK_LXD_PORT` | `--port` | `8080` |
| Conda env name | `AK_LXD_CONDA_ENV` | — | `ak-lxd-helper` |
| LXD host (dev forward + host stats SSH) | `LXD_HOST` | — | — |
| Remote socket (dev forward only) | `LXD_REMOTE_SOCKET` | — | `/var/snap/lxd/common/lxd/unix.socket` |
| Host-stats source | `HOST_STATS` | — | `auto` (local on-host, else SSH `LXD_HOST`); `local\|ssh\|off` |
| VM SSH user | `LAB_VM_USER` | — | `lab` |
| VM SSH password | `LAB_VM_PASSWORD` | — | _(set in `.env`)_ |
| macvlan parent NIC | `LAB_LAN_PARENT` | — | `enP7s7` |

¹ Auto-detection order: `$LXD_SOCKET` → `/var/snap/lxd/common/lxd/unix.socket`
→ `~/.lxd.socket` → `/tmp/lxd.socket`.

---

## Using the dashboard

- **Dashboard tab** — live resource monitor: host CPU%, memory, GPU(s), disk, and
  network (auto-refresh every 3s), plus a per-instance CPU/memory/network table.
  Host stats come from the host (`/proc` + `nvidia-smi`), run locally on-host or over
  SSH to `$LXD_HOST` (see `HOST_STATS`); shows "unavailable" if neither is reachable.
- **Instances tab**
  - **+ New instance** — name it, pick container vs VM, choose a local image or
    pull a remote one (e.g. server `https://cloud-images.ubuntu.com/releases`,
    alias `24.04`), optionally set `limits.cpu` / `limits.memory`.
  - **Open** an instance for sub-tabs:
    - *Overview* — status, network, memory, profiles.
    - *Devices* — attached drives (pool/source/size/boot priority), configured NICs,
      live interfaces (MAC/MTU/host veth/addresses), and the bridge/network details
      (type, IPv4/IPv6, NAT) for each network the instance is attached to.
    - *Config* — edit config/description/profiles as JSON (saved with PATCH, which merges).
    - *Run* — execute a single command, see stdout/stderr/exit code.
    - *Logs* — host-side LXD log files + quick in-guest `journalctl`/`cloud-init`/`syslog`.
    - *Terminal* — interactive shell (instance must be running; needs the lxd-agent, i.e. an installed OS).
    - *Console* — serial console (see notes below).
  - The *Overview* tab shows an **LAN access** card with the VM's LAN IP, SSH
    username/password, and a copyable `ssh` command (see "LAN access" below).
  - Row buttons: Start / Stop / Restart / Delete.
- **Images tab** — import, alias, edit, delete images.

### Console notes (important for serial consoles)

The console attaches to the instance's **serial** console. A few quirks are
inherent to serial consoles, not bugs:

- **Attaching doesn't repaint.** You only see output while something is actively
  printing. Connecting to an idle full-screen TUI (e.g. an installer at a menu)
  shows a blank screen — press **Redraw** or an arrow key, or connect during boot.
- **Click into the terminal** to give it keyboard focus before typing.
- **One console at a time.** A VM allows a single console connection; close stale
  ones if a reconnect reports the console is busy.
- For a graphical installer experience, the Ubuntu installer's *"connect over SSH"*
  option gives the full rich TUI.

---

## Booting a VM from an ISO

The whole flow is supported (currently via the API / a structured create; ISO
upload is path-based — the server reads a file from the machine it runs on):

```bash
# 1. Create an empty VM (no image, blank root disk)
curl -X POST localhost:8080/api/instances -H 'content-type: application/json' -d '{
  "name":"vm1","type":"virtual-machine","empty":true,
  "config":{"limits.cpu":"2","limits.memory":"4GiB"},
  "devices":{"root":{"type":"disk","path":"/","pool":"default","size":"20GiB"}}}'

# 2. Upload an ISO as a custom volume (path is read on the server host)
curl -X POST localhost:8080/api/storage/default/isos -H 'content-type: application/json' \
  -d '{"name":"ubuntu-iso","path":"/path/to/ubuntu.iso"}'

# 3. Attach it as a bootable disk
curl -X POST localhost:8080/api/instances/vm1/devices -H 'content-type: application/json' \
  -d '{"name":"install-iso","device":{"type":"disk","pool":"default","source":"ubuntu-iso","boot.priority":"10"}}'

# 4. Start and watch the Console tab
curl -X POST localhost:8080/api/instances/vm1/state -H 'content-type: application/json' -d '{"action":"start"}'
```

After the OS is installed, **detach the ISO** so the VM boots from disk:

```bash
curl -X DELETE localhost:8080/api/instances/vm1/devices/install-iso
```

---

## API reference (for scripting)

All responses are `{"ok": true, "data": …}` or `{"ok": false, "error": …}`.

| Method & path | Purpose |
|---------------|---------|
| `GET /api/server` | LXD server/environment info |
| `GET /api/resources` | Host hardware (cpu/memory/gpu) |
| `GET /api/host/stats` | Live host CPU%/mem/disk/net + GPU (nvidia-smi) |
| `GET /api/instances/{name}/access` | SSH access info: LAN IP, username, password, `ssh` cmd |
| `GET /api/instances/{name}/logs` | List host-side log files |
| `GET /api/instances/{name}/logs/{file}` | Log file contents |
| `GET /api/instances` | List instances (recursion=2) |
| `POST /api/instances` | Create (see payload below) |
| `GET /api/instances/{name}` | Details + runtime state |
| `PATCH /api/instances/{name}` | Merge config/description/profiles |
| `DELETE /api/instances/{name}` | Delete |
| `POST /api/instances/{name}/state` | `{"action":"start\|stop\|restart\|freeze\|unfreeze","force":bool}` |
| `POST /api/instances/{name}/exec` | `{"command":"uname -a"}` → stdout/stderr/return |
| `POST /api/instances/{name}/devices` | `{"name","device":{…}}` attach a device |
| `DELETE /api/instances/{name}/devices/{device}` | Detach a device |
| `GET\|POST /api/instances/{name}/snapshots` | List / create snapshots |
| `POST /api/instances/{name}/snapshots/restore` | Restore (`{"name":snap}`) |
| `DELETE /api/instances/{name}/snapshots/{snap}` | Delete a snapshot |
| `GET /api/images` | List images |
| `POST /api/images/import` | `{"server","alias","protocol?","alias_local?","image_type?"}` |
| `GET\|PATCH\|DELETE /api/images/{fingerprint}` | Inspect / edit / delete |
| `POST /api/images/aliases` | `{"fingerprint","name","description?"}` |
| `DELETE /api/images/aliases/{name}` | Remove an alias |
| `GET /api/networks` | List networks/bridges |
| `GET /api/networks/{name}` | Network config + runtime state |
| `GET /api/profiles` | List profiles |
| `GET /api/profiles/{name}` | Profile config |
| `PUT /api/profiles/{name}` | Create/replace a profile |
| `GET /api/storage` | List storage pools |
| `GET /api/storage/{pool}/volumes` | List volumes in a pool |
| `POST /api/storage/{pool}/isos` | `{"name","path"}` upload a server-local ISO |
| `DELETE /api/storage/{pool}/volumes/{name}` | Delete a custom volume |
| `GET /ws/exec/{name}?cmd=/bin/bash` | Interactive exec (WebSocket) |
| `GET /ws/console/{name}` | Console (WebSocket) |

Create-instance payload:

```json
{
  "name": "web1",
  "type": "container",
  "start": true,
  "config": { "limits.cpu": "2", "limits.memory": "4GiB" },
  "image": { "server": "https://cloud-images.ubuntu.com/releases",
             "protocol": "simplestreams", "alias": "24.04" }
}
```

- Local image instead of a pull: `"image": {"fingerprint": "<fp>"}` or `{"alias": "<local-alias>"}`.
- Empty VM (install from ISO): omit `image` or set `"empty": true`.

### Raw API debugging

```bash
scripts/lxc-api.sh GET /1.0
scripts/lxc-api.sh GET /1.0/instances?recursion=2
scripts/lxc-api.sh POST /1.0/instances/web1/state '{"action":"start"}'
```

---

## Project layout

```
ak-lxd-helper/
├── AGENTS.md               # project brief
├── README.md
├── .env.example            # copy to .env (gitignored) and edit
├── .gitignore
├── environment.yml         # conda env (python 3.12 + aiohttp)
├── bin/ak-lxd-helper       # launcher (sources .env, creates env, runs server)
├── scripts/
│   ├── forward-socket.sh   # SSH-forward the LXD socket for local dev
│   ├── lxc-api.sh          # raw curl helper for the LXD socket
│   └── console_input_test.py # stdlib console I/O diagnostic (optional)
├── src/aklxd/
│   ├── config.py           # socket/host/port resolution
│   ├── lxd.py              # async LXD REST client
│   ├── host.py             # async host stats (/proc + nvidia-smi, local or ssh)
│   └── server.py           # aiohttp app: REST + WebSocket proxy
├── web/
│   ├── index.html
│   ├── style.css
│   └── app.js              # dashboard SPA (xterm.js via CDN)
├── lab/                    # spec-driven LXD experiments
│   ├── README.md           # lab "constitution" + conventions
│   ├── PROJECTS.md         # running record of every mini-project
│   ├── specs/              # one lightweight spec per project
│   ├── profiles/           # cloud-init / LXD profiles
│   ├── scripts/
│   │   ├── lab.sh          # CLI over the dashboard API
│   │   └── host-vfio-setup.sh  # discrete-GPU VFIO setup (does NOT work on GB10)
│   └── tests/lab-004-005.sh    # end-to-end unit tests
└── .claude/skills/         # reusable Claude Code skills (committed)
    ├── lxd-vm-create/
    ├── lxd-vm-provision/
    ├── lxd-multi-connect/
    └── lxd-vm-manage/
```

---

## Security notes

- The dashboard exposes **full control of LXD** with no authentication. Bind to
  `127.0.0.1` (the default) and reach it over SSH, or put it behind a trusted
  network / reverse proxy with auth. Do **not** expose it to the internet.
- It talks only to the local LXD Unix socket; there is no TLS and no remote LXD
  credential handling by design.
- Host-specific config lives in `.env` (gitignored). Keep it out of commits.
- xterm.js and its fit addon load from jsdelivr's CDN; if the host has no
  internet, vendor those two files into `web/` and update the `<script>`/`<link>`
  tags in `index.html`.

---

## Troubleshooting

- **"Cannot reach LXD socket"** — the socket path doesn't exist or isn't
  readable. Check the SSH forward is up (dev) or your group membership (host);
  verify with `scripts/lxc-api.sh GET /1.0`.
- **Console is blank** — serial consoles don't repaint on attach.
  - At a **login prompt** (a booted OS): click into the terminal and press **Enter** —
    a getty only re-prints `… login:` when you press Enter; **Redraw** won't help it.
  - At a **full-screen app** (the installer): press **Redraw** or an arrow key, or
    reconnect during boot to catch it actively drawing.
- **Console input does nothing** — click into the terminal to give it focus first.
- **Console "busy" / won't reconnect** — a VM allows only one console connection;
  a stale session may still hold the slot. Close other tabs/clients, or (dev)
  reset the SSH forward to drop half-open connections. Check with
  `scripts/lxc-api.sh GET /1.0/operations`.
- **Terminal tab won't connect** — interactive `exec` needs the **lxd-agent** inside
  the guest. LXD cloud images ship it; an OS installed from a stock ISO does **not**.
  Use **Console** or SSH, or install the agent (see below).
- **VM reboots back into the installer** — the install ISO is still attached with a
  high `boot.priority`. Detach it so the VM boots from disk:
  `DELETE /api/instances/{name}/devices/install-iso` (stop the VM first), then start.
- **VM has no internet / `apt update` fails** — usually the Docker + LXD bridge
  conflict. See [Networking: instances can't reach the internet](#networking-instances-cant-reach-the-internet).
- **Image/ISO transfer seems stuck** — large transfers run in the background; the
  call waits a long time before timing out.
- **First launch is slow** — conda is building the env. Subsequent launches reuse it.

### Enabling the Terminal tab on an ISO-installed VM

`exec` (the Terminal tab) needs the lxd-agent. To add it to a VM you installed from
an ISO, log in via **Console** and run:

```bash
sudo mkdir -p /run/lxd_agent
sudo mount -t 9p config /run/lxd_agent      # LXD's agent config share
sudo /run/lxd_agent/install.sh
sudo systemctl enable --now lxd-agent
```

After that the Terminal tab connects directly.

### Networking: instances can't reach the internet

**Symptom:** an instance gets an IP and can ping its gateway (`lxdbr0`, e.g.
`10.10.249.1`), but can't reach external IPs (`ping 8.8.8.8` fails) or resolve names,
so `apt update` and `ping <site>` fail.

**Cause:** if **Docker** is installed on the LXD host, it sets the iptables
`FORWARD` chain policy to `DROP` and only accepts traffic for its own bridges.
Forwarded traffic from `lxdbr0` falls through to that `DROP` and is silently
discarded. Confirm on the host:

```bash
sudo iptables -S FORWARD          # shows "-P FORWARD DROP" and only DOCKER* jumps
```

**Fix:** whitelist the LXD bridge in Docker's user chain (evaluated before the DROP):

```bash
sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
sudo iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT
# IPv6, if used: repeat with `sudo ip6tables -I DOCKER-USER ...`
```

Re-test from the instance: `ping -c2 8.8.8.8`. Make it survive reboots:

```bash
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

> Diagnosing inside the guest: `ip route` (default via the bridge?),
> `ping 10.10.249.1` (gateway), `ping 8.8.8.8` (forwarding/NAT),
> `ping example.com` (DNS).

---

## LAN access (SSH into VMs)

By default LXD VMs sit on the private `lxdbr0` bridge — reachable from the host and
from each other, but **not** from your LAN. To SSH into a VM directly from your
network, the `base-ubuntu` lab profile gives each VM a **second NIC via macvlan** on
the host's LAN interface (`LAB_LAN_PARENT`, default `enP7s7`), so the VM gets its own
LAN IP (e.g. `192.168.1.x`) while keeping `eth0` on `lxdbr0` for inter-VM traffic. The
profile's cloud-init also creates `LAB_VM_USER` with `LAB_VM_PASSWORD` and enables
password SSH.

- **New VMs** (created from the profile) get this automatically.
- **Existing VMs:** `lab/scripts/lab.sh expose-lan <name>` hot-adds the macvlan NIC and
  sets up the user/password.
- The instance **Overview → LAN access** card shows the LAN IP + credentials + `ssh`
  command. Then from your laptop: `ssh lab@<vm-lan-ip>`.

Notes:
- **macvlan caveat:** the *host* cannot reach its own macvlan guests by IP (a kernel
  limitation), but the rest of the LAN can, and the dashboard console/exec are
  unaffected (they use the lxd-agent over vsock, not the network).
- Credentials live in gitignored `.env`; the Access endpoint returns the password in
  plaintext for display — keep the dashboard bound to `127.0.0.1`.
- Alternatives if you prefer: a `proxy` device (NAT port-forward, host-IP:port) or a
  host bridge over the physical NIC (real LAN IP + host↔VM, but reconfigures host
  networking).

## Lab: spec-driven multi-system experiments

[`lab/`](lab/) is a spec-driven workspace for building and testing multi-VM (and
multi-container) experiments on the host. Each experiment is a short spec in
[`lab/specs/`](lab/specs); reusable building blocks are **Claude Code skills** in
[`.claude/skills/`](.claude/skills) (`lxd-vm-create`, `lxd-vm-provision`,
`lxd-multi-connect`, `lxd-vm-manage`); [`lab/PROJECTS.md`](lab/PROJECTS.md) is the
running record. Provisioning is declarative (cloud-init + LXD profiles), driven
through the dashboard API by [`lab/scripts/lab.sh`](lab/scripts/lab.sh). See
[`lab/README.md`](lab/README.md) for conventions.

### Projects

| # | What it builds | Skills | Spec |
|---|---|---|---|
| 001 | Ubuntu base VM + prereqs (python, conda) | `lxd-vm-create` | [001](lab/specs/001-ubuntu-base.md) |
| 002 | LLM serving via **Ollama** on a VM | `lxd-vm-create`, `lxd-vm-provision` | [002](lab/specs/002-llm-serving-ollama.md) |
| 003 | **Open WebUI ↔ Ollama** (two VMs talking over `lxdbr0`) | + `lxd-multi-connect` | [003](lab/specs/003-openwebui-ollama.md) |
| 004 | **vLLM** serving Qwen3-8B on the GB10 GPU (**container** with `nvidia.runtime`; VM passthrough is rejected by GB10 firmware) | `lxd-vm-create` (container), `lxd-vm-provision` | [004](lab/specs/004-vllm-qwen.md) |
| 005 | **pi** agent harness (earendil-works) wired to lab-004's vLLM + persistent tmux | + `lxd-multi-connect` | [005](lab/specs/005-pi-with-qwen.md) |

### Quick start: spin up a lab project

```bash
# 0. one-time setup (dev laptop): forward the socket, run the dashboard
scripts/forward-socket.sh &      # leave running
bin/ak-lxd-helper                # http://127.0.0.1:8080
# (or on the LXD host directly, just bin/ak-lxd-helper)

# 1. apply the base-ubuntu profile (cloud-init + macvlan LAN NIC)
lab/scripts/lab.sh profile-apply base-ubuntu

# 2. project 001 — base Ubuntu VM with python + conda
lab/scripts/lab.sh create  lab-001-ubuntu-base
lab/scripts/lab.sh wait    lab-001-ubuntu-base
lab/scripts/lab.sh verify  lab-001-ubuntu-base

# 3. project 002 — Ollama on a VM (see spec for provisioning recipe)
lab/scripts/lab.sh create  lab-002-ollama
lab/scripts/lab.sh wait    lab-002-ollama
# install + smoke-test per lab/specs/002-llm-serving-ollama.md

# 4. project 004 — vLLM in a GPU-sharing CONTAINER (Grace-Blackwell path)
#    create a GPU profile (gpu device + nvidia.runtime=true + 100GiB disk)
#    then: lab.sh create-container lab-004-vllm base-ubuntu,gpu-share
#    full recipe: lab/specs/004-vllm-qwen.md

# 5. project 005 — pi wired to lab-004 + persistent tmux
#    full recipe: lab/specs/005-pi-with-qwen.md
#    once running, from your laptop:
#      alias pi='ssh -t lab@<lab-005-LAN-IP> pi-tmux'
#      pi   # drops into the live coding-agent session

# end-to-end unit tests for projects 004 + 005:
bash lab/tests/lab-004-005.sh

# day-to-day management (any project):
lab/scripts/lab.sh snapshot|restore|snap-rm|start|stop|restart|pkg|device-add|device-rm|delete
```

The dashboard's **Devices** and **LAN access** cards show each instance's
networking + the `ssh` command to reach it from the LAN.

## Roadmap

Per `AGENTS.md`, future additions may include snapshots, network/storage management,
file push/pull, browser file-upload for ISOs, GPU passthrough, and resource graphs.

## License

[MIT](LICENSE) © 2026 Andrew Knight.
