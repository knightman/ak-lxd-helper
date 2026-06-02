# lxd-vm-create — reference

## What it builds

A `virtual-machine` instance created from the `ubuntu:<release>` simplestreams cloud
image (default `24.04`), attached to the `base-ubuntu` profile. The profile carries:

- `limits.cpu` / `limits.memory` (defaults 2 / 4GiB)
- a `root` disk on pool `default` (default 20GiB) and an `eth0` NIC on `lxdbr0`
- `cloud-init.user-data` from `lab/profiles/base-ubuntu.cloud-init.yaml`

### cloud-init (base-ubuntu)

Installs `python3`, `python3-pip`, `python3-venv`, `build-essential`, `git`, `curl`,
`ca-certificates`, then installs **Miniforge** to `/opt/conda` (arch-aware via
`uname -m`, idempotent) and symlinks `conda` into `/usr/local/bin`.

## Why cloud images (not an ISO)

Ubuntu cloud images ship `cloud-init` and the `lxd-agent`. That means provisioning is
declarative and `exec`/Terminal work the moment the agent is up — no manual
`lxd-agent` install or ISO detach (the pain points of an ISO install).

## Parameters

| Env var | Default | Meaning |
|---------|---------|---------|
| `LAB_RELEASE` | `24.04` | Ubuntu cloud-image alias |
| `LAB_CPU` | `2` | `limits.cpu` baked into the profile on `profile-apply` |
| `LAB_MEM` | `4GiB` | `limits.memory` |
| `LAB_DISK` | `20GiB` | root disk size |
| `LAB_IMAGE_SERVER` | `https://cloud-images.ubuntu.com/releases` | simplestreams server |
| `AK_LXD_URL` | `http://127.0.0.1:8080` | dashboard API base |

Re-run `profile-apply` after changing CPU/MEM/DISK to update the profile (existing
VMs are not retroactively changed).

## Containers (GPU workloads, Grace-Blackwell)

`lab.sh create-container <name> [profiles_csv]` creates an LXD **container** (vs
the VM created by `create`) by passing `image_type: container` to the helper. Use
this for GPU workloads on **Grace-Blackwell / GB10** where VM GPU passthrough is
rejected by the platform firmware (`vfio-pci ... 1:1 IOMMU mapping required`).

A GPU-sharing container needs a profile with:

```yaml
config:
  nvidia.runtime: "true"      # NVIDIA Container Toolkit on the host
  limits.memory: 32GiB        # the limit is what vLLM sees as "GPU memory" (unified-mem)
devices:
  gpu0: { type: gpu, gputype: physical }
  root: { path: /, pool: default, size: 100GiB, type: disk }
```

The host must have `nvidia-container-toolkit` installed (`nvidia-container-cli
--version`) and LXD must report `nvidia_runtime` in `lxc info`. See spec 004.

## How it maps to the helper API

- `profile-apply` → `PUT /api/profiles/base-ubuntu`
- `create` → `POST /api/instances` with `{type:"virtual-machine", profiles:["base-ubuntu"], image:{server,protocol:"simplestreams",alias}}`
- `wait` / `verify` / `exec` → `POST /api/instances/<name>/exec`
- `ip` → `GET /api/instances/<name>` (reads `state.network`)
- `teardown` → `POST .../state {stop,force}` then `DELETE /api/instances/<name>`

## Troubleshooting

- **`verify` shows `network(apt): NET_FAIL`** → host Docker `FORWARD DROP` is blocking
  `lxdbr0`. Apply the `DOCKER-USER` ACCEPT rules (repo README → Networking), then
  re-run `verify`.
- **`wait` times out** → check the console (`/ws/console/<name>`) for a cloud-init
  error; `cloud-init.user-data` typos surface as `status: error`.
- **`exec` fails immediately after create** → the agent isn't up yet; `wait` retries
  until it is. If it never comes up, confirm the image was a *cloud* image (has the agent).
- **`conda --version` fails but python works** → the Miniforge `runcmd` may still be
  downloading; re-run `verify` after `wait` reports done.
