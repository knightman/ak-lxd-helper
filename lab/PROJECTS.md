# Lab projects — record

The running record of every mini-project. Status: 🟢 done · 🟡 in progress · ⚪ planned.
Each row links to its spec; "Skills" lists the building blocks it composes.

| # | Project | Status | Spec | Skills used | Instance(s) |
|---|---------|--------|------|-------------|-------------|
| 001 | Ubuntu base VM + prereqs (python, conda) | 🟢 done | [001](specs/001-ubuntu-base.md) | `lxd-vm-create` | `lab-001-ubuntu-base` |
| 002 | LLM serving (Ollama) on a VM | ⚪ planned | [002](specs/002-llm-serving-ollama.md) | `lxd-vm-create`, `lxd-vm-provision` | `lab-002-ollama` |
| 003 | Open WebUI ↔ Ollama (two VMs) | ⚪ planned | [003](specs/003-openwebui-ollama.md) | `lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect` | `lab-003-openwebui`, `lab-002-ollama` |

## Log

- 2026-05-28 — **001 PASS.** `lab-001-ubuntu-base` (VM, ubuntu 24.04, aarch64) created
  from cloud image via `base-ubuntu` profile. cloud-init done; Python 3.12.3; conda
  26.3.2 (Miniforge /opt/conda); `apt-get update` OK (network); IP 10.10.249.249.
  Networking precondition (Docker `DOCKER-USER` fix) confirmed in place.

## How to add a project

1. Copy `specs/_TEMPLATE.md` to `specs/NNN-<slug>.md` and fill it in.
2. Add a row above (status ⚪ planned).
3. Implement by composing skills; flip status to 🟡 then 🟢 and fill the spec's *Results*.
