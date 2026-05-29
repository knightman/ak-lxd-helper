# ak-lxd-helper lab

A spec-driven workspace for building and testing **multi-system experiments** on the
LXD host (configured via `LXD_HOST` in `.env`) using the dashboard/API in this repo.
Each experiment is a small,
testable **spec**; the reusable work is captured as composable **skills** under
`.claude/skills/`. [`PROJECTS.md`](PROJECTS.md) is the running record of every
mini-project.

## Principles (the "constitution")

1. **Spec first.** Every mini-project starts as a short spec in `specs/` (copy
   `_TEMPLATE.md`): goal, inputs, acceptance criteria, steps, verification, teardown.
   The spec is the contract — implement to it, then record the result.
2. **Compose skills, don't reinvent.** Experiments are built from building-block
   skills (`lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect`). New reusable
   behavior becomes a new skill, not a one-off script.
3. **Declarative & reproducible.** VMs come from **Ubuntu cloud images** (which include
   `cloud-init` *and* the `lxd-agent`, so `exec`/Terminal work immediately) provisioned
   via **cloud-init** in an LXD **profile** (`profiles/`). Avoid ISO installs unless an
   experiment specifically needs one.
4. **Verification-first & idempotent.** Every skill ends by asserting its acceptance
   criteria and is safe to re-run.
5. **Managed through the helper.** All LXD operations go through the dashboard API
   (`lab/scripts/lab.sh`), so the helper stays the single management surface.
6. **Clean up.** Instances are named `lab-NNN-<slug>`; every spec has a teardown step.

## Conventions

- **Instance names:** `lab-001-ubuntu-base`, `lab-002-ollama`, …
- **Base profile:** `profiles/base-ubuntu.yaml` → LXD profile `base-ubuntu`.
- **Record:** update [`PROJECTS.md`](PROJECTS.md) and the spec's *Results* section after each run.

## Prerequisites

- The dashboard server is running and pointed at the LXD socket
  (`bin/ak-lxd-helper`; dev: `scripts/forward-socket.sh` first). `lab.sh` calls
  `AK_LXD_URL` (default `http://127.0.0.1:8080`).
- **Networking:** the Docker `DOCKER-USER` ACCEPT rules must be applied on the host
  (see the repo README "Networking" troubleshooting) or cloud-init can't fetch packages.

## Using `lab.sh`

```bash
lab/scripts/lab.sh profile-apply base-ubuntu          # upload profiles/base-ubuntu.yaml
lab/scripts/lab.sh create lab-001-ubuntu-base         # launch from base-ubuntu profile
lab/scripts/lab.sh wait   lab-001-ubuntu-base         # wait for cloud-init to finish
lab/scripts/lab.sh exec   lab-001-ubuntu-base "python3 --version"
lab/scripts/lab.sh ip     lab-001-ubuntu-base
lab/scripts/lab.sh verify lab-001-ubuntu-base         # assert acceptance criteria
lab/scripts/lab.sh teardown lab-001-ubuntu-base       # stop + delete
```

## Layout

```
lab/
├── README.md            # this file
├── PROJECTS.md          # record of all mini-projects + status
├── specs/               # one lightweight spec per project (+ _TEMPLATE.md)
├── profiles/            # LXD profiles w/ cloud-init (base-ubuntu.yaml)
└── scripts/lab.sh       # CLI over the dashboard API
```

Skills (reusable building blocks) live in `../.claude/skills/`.
