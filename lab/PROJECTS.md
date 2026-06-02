# Lab projects — record

The running record of every mini-project. Status: 🟢 done · 🟡 in progress · ⚪ planned.
Each row links to its spec; "Skills" lists the building blocks it composes.

| # | Project | Status | Spec | Skills used | Instance(s) |
|---|---------|--------|------|-------------|-------------|
| 001 | Ubuntu base VM + prereqs (python, conda) | 🟢 done | [001](specs/001-ubuntu-base.md) | `lxd-vm-create` | `lab-001-ubuntu-base` |
| 002 | LLM serving (Ollama) on a VM | 🟢 done | [002](specs/002-llm-serving-ollama.md) | `lxd-vm-create`, `lxd-vm-provision` | `lab-002-ollama` |
| 003 | Open WebUI ↔ Ollama (two VMs) | 🟢 done | [003](specs/003-openwebui-ollama.md) | `lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect` | `lab-003-openwebui`, `lab-002-ollama` |
| 004 | vLLM serving Qwen3-8B on GB10 (container, GPU shared) | 🟢 done | [004](specs/004-vllm-qwen.md) | `lxd-vm-create` (container), `lxd-vm-provision` | `lab-004-vllm` |
| 005 | pi agent harness wired to lab-004 vLLM + persistent tmux | 🟢 done | [005](specs/005-pi-with-qwen.md) | `lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect` | `lab-005-pi`, `lab-004-vllm` |

## Log

- 2026-05-28 — **001 PASS.** `lab-001-ubuntu-base` (VM, ubuntu 24.04, aarch64) created
  from cloud image via `base-ubuntu` profile. cloud-init done; Python 3.12.3; conda
  26.3.2 (Miniforge /opt/conda); `apt-get update` OK (network); IP 10.10.249.249.
  Networking precondition (Docker `DOCKER-USER` fix) confirmed in place.
- 2026-05-28 — **002 PASS.** `lab-002-ollama`: ollama 0.24.0 installed (CPU-only, no GPU
  passthrough), bound `0.0.0.0:11434`, `llama3.2:1b` pulled, `/api/generate` returned a
  real completion. Bridge IP 10.10.249.8 (for 003). Large arm64 bundle + model pull run
  detached+polled to dodge the 300s exec timeout.
- 2026-05-28 — **003 PASS.** `lab-003-openwebui`: open-webui 0.9.5 (conda py3.11, CPU
  torch — pre-installed CPU torch to avoid multi-GB CUDA wheels), service on
  `0.0.0.0:8080`, `OLLAMA_BASE_URL=http://10.10.249.8:11434`. lxd-multi-connect verified:
  cross-VM reach over lxdbr0, Open WebUI `/api/models` lists `llama3.2:1b`, and a
  completion proxied through Open WebUI → Ollama VM returned text. Both VMs left running.
- 2026-06-02 — **004 PASS.** `lab-004-vllm`: **container** (not VM — GB10 firmware
  rejects VFIO passthrough with "1:1 IOMMU mapping required"; container path with
  `nvidia.runtime=true` is canonical on Grace-Blackwell). vLLM 0.22.0 + torch 2.11.0
  + CUDA 13 stack; serves `Qwen/Qwen3-8B` on `0.0.0.0:8000` with
  `--gpu-memory-utilization 0.20 --max-model-len 8192`. Bridge IP 10.10.249.171.
- 2026-06-02 — **005 PASS.** `lab-005-pi`: pi (earendil-works) built from source on
  Node 24 (Node 20 can't run pi's TS build scripts); `~/.pi/agent/models.json`
  registers `vllm` provider with `api: openai-completions` pointing at lab-004; pi
  one-shot routes through vLLM and returns Qwen3-8B text. Persistent tmux session
  `pi` via systemd user unit (lingering enabled). LAN SSH: `ssh lab@192.168.1.152`
  then `pi-tmux`. All 10 checks in `lab/tests/lab-004-005.sh` green.

## How to add a project

1. Copy `specs/_TEMPLATE.md` to `specs/NNN-<slug>.md` and fill it in.
2. Add a row above (status ⚪ planned).
3. Implement by composing skills; flip status to 🟡 then 🟢 and fill the spec's *Results*.
