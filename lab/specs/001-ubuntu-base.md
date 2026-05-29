# 001 — Ubuntu base VM + prereqs (python, conda)

- **Status:** 🟢 done (2026-05-28)
- **Skills:** `lxd-vm-create`
- **Instance:** `lab-001-ubuntu-base`

## Goal

Stand up a fresh Ubuntu Server VM from a cloud image and confirm it boots with the
baseline developer prerequisites installed and reachable: working network, Python 3,
and conda (Miniforge). This is the reference build that every later experiment starts
from.

## Inputs / parameters

| Name | Default | Notes |
|------|---------|-------|
| release | 24.04 | `ubuntu:24.04` cloud image (arm64) |
| cpu | 2 | |
| memory | 4GiB | |
| disk | 20GiB | |

Provisioning is declarative via the `base-ubuntu` profile
(`lab/profiles/base-ubuntu.yaml`), whose cloud-init installs the prereqs.

## Preconditions

- Dashboard server running and reaching the LXD socket.
- Docker `DOCKER-USER` networking fix applied on the host (cloud-init needs internet).

## Steps

1. `lab.sh profile-apply base-ubuntu` — upload/refresh the LXD profile.
2. `lxd-vm-create` → `lab.sh create lab-001-ubuntu-base` — launch from `base-ubuntu`.
3. `lab.sh wait lab-001-ubuntu-base` — block on `cloud-init status --wait`.
4. `lab.sh verify lab-001-ubuntu-base` — assert acceptance criteria.

## Acceptance criteria

- [x] Instance is **Running** and `exec` works (lxd-agent present — proves cloud image).
- [x] `cloud-init status` reports `done`.
- [x] External network works: `apt-get update` succeeds inside the VM.
- [x] `python3 --version` ≥ 3.10.
- [x] `conda --version` succeeds (Miniforge at `/opt/conda`).

## Verification

```bash
lab/scripts/lab.sh exec lab-001-ubuntu-base "cloud-init status"
lab/scripts/lab.sh exec lab-001-ubuntu-base "python3 --version"
lab/scripts/lab.sh exec lab-001-ubuntu-base "conda --version"
lab/scripts/lab.sh exec lab-001-ubuntu-base "sudo apt-get update -qq && echo NET_OK"
# or all at once:
lab/scripts/lab.sh verify lab-001-ubuntu-base
```

## Teardown

```bash
lab/scripts/lab.sh teardown lab-001-ubuntu-base
```

## Results

**2026-05-28 — PASS.** Created via `lab.sh profile-apply base-ubuntu` →
`lab.sh create lab-001-ubuntu-base` (ubuntu 24.04 cloud image, aarch64) →
`lab.sh wait` → `lab.sh verify`:

```
cloud-init:     status: done
python3:        Python 3.12.3
conda:          conda 26.3.2          # Miniforge at /opt/conda
network(apt):   NET_OK
RESULT: PASS
```

IP: `10.10.249.249` (lxdbr0). lxd-agent present (exec worked out of the box — cloud
image, no manual agent install). Networking precondition (Docker `DOCKER-USER` fix)
confirmed in place before the run.
