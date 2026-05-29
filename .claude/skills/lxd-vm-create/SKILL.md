---
name: lxd-vm-create
description: Create an Ubuntu cloud-image VM on the LXD host via the ak-lxd-helper dashboard and verify it booted with baseline prereqs (network, python3, conda, lxd-agent). Use when a lab experiment needs a fresh, reproducible base VM. Powers lab project 001.
---

# lxd-vm-create

Launch a reproducible Ubuntu Server VM for lab experiments and confirm it is usable.
Uses Ubuntu **cloud images** (which include cloud-init + the lxd-agent, so `exec`
works immediately) provisioned by the `base-ubuntu` LXD profile's cloud-init.

## When to use

- A spec needs a fresh base VM with python3 + conda (e.g. lab project 001), or as the
  first step of a larger experiment (projects 002/003).

## Prerequisites

- The dashboard server is running and reaching the LXD socket
  (`bin/ak-lxd-helper`; dev: `scripts/forward-socket.sh` first).
- The Docker `DOCKER-USER` networking fix is applied on the host, or cloud-init can't
  fetch packages (see repo README → Troubleshooting → Networking). The verify step
  will catch this as `network(apt): NET_FAIL`.

## Workflow

All commands go through `lab/scripts/lab.sh` (the helper API). Replace `<name>` with
a `lab-NNN-<slug>` instance name.

1. **Apply the base profile** (idempotent):
   ```bash
   lab/scripts/lab.sh profile-apply base-ubuntu
   ```
2. **Create + start the VM:**
   ```bash
   lab/scripts/lab.sh create <name>            # default profile base-ubuntu, release 24.04
   ```
3. **Wait for cloud-init** to finish (installs packages + Miniforge):
   ```bash
   lab/scripts/lab.sh wait <name>
   ```
4. **Verify** the acceptance criteria:
   ```bash
   lab/scripts/lab.sh verify <name>            # cloud-init done, python3, conda, apt update
   ```
5. **Record** the result in `lab/PROJECTS.md` and the project's spec *Results* section.

Parameters (env vars consumed by `lab.sh`): `LAB_RELEASE` (default 24.04),
`LAB_CPU`/`LAB_MEM`/`LAB_DISK` (2 / 4GiB / 20GiB), `LAB_IMAGE_SERVER`.

## Success criteria

`verify` prints `RESULT: PASS` — meaning `exec` works (agent present), `cloud-init
status` = done, `python3 --version` and `conda --version` succeed, and `apt-get
update` works (external network OK).

## Teardown

```bash
lab/scripts/lab.sh teardown <name>
```

See `reference.md` for the cloud-init contents, parameters, and troubleshooting.
