# lxd-vm-provision — reference

## General principles

- **Guide-driven, not memory-driven.** Always fetch the current official install
  guide/repo and follow its steps; record the exact commands you ran in the spec.
- **Idempotent.** Guard steps so re-running is safe (`test -x … || install`).
- **exec runs as root** in the VM (no `sudo` needed). Long installs may exceed the
  exec operation timeout — split into steps or run in the background and poll.
- **Reachability.** For services other VMs will consume, bind to `0.0.0.0` and confirm
  the listening socket (`ss -ltnp`).

## Example: Ollama (lab project 002 — verified 2026-05-28)

The arm64 install bundle is **large** (it ships GPU/CUDA runtime even unused) and the
model pull is ~1.3 GB — **both exceed the 300s exec timeout**, so run them **detached
and poll** (do NOT call `install.sh`/`ollama pull` as a single blocking `exec`).

```bash
VM=lab-002-ollama
# 1) install — detached, then poll for the ollama user (created at the very end)
lab/scripts/lab.sh exec $VM \
  "setsid bash -c 'curl -fsSL https://ollama.com/install.sh | sh > /var/log/ollama-install.log 2>&1' </dev/null >/dev/null 2>&1 & echo launched"
#    poll: until `id ollama` succeeds (or `systemctl cat ollama` exists)
# 2) bind to all interfaces so other VMs can reach it
lab/scripts/lab.sh exec $VM \
  "mkdir -p /etc/systemd/system/ollama.service.d && \
   printf '[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"\n' \
     > /etc/systemd/system/ollama.service.d/override.conf && \
   systemctl daemon-reload && systemctl restart ollama"
# 3) pull a small model — detached, then poll `ollama list` for the model
lab/scripts/lab.sh exec $VM \
  "setsid bash -c 'ollama pull llama3.2:1b > /var/log/ollama-pull.log 2>&1' </dev/null >/dev/null 2>&1 & echo launched"
# 4) smoke test
lab/scripts/lab.sh exec $VM "curl -s localhost:11434/api/tags"
lab/scripts/lab.sh exec $VM "curl -s localhost:11434/api/generate -d '{\"model\":\"llama3.2:1b\",\"prompt\":\"hi\",\"stream\":false}'"
```

Acceptance: `ollama --version` works, service active, `ss` shows `LISTEN *:11434`,
`/api/tags` lists the model, and `/api/generate` returns text. (CPU-only unless GPU
passthrough is configured — `install.sh` warns "No NVIDIA/AMD GPU detected".)

## Example: vLLM serving on GB10 (lab project 004 — verified 2026-06-02)

Use a GPU-sharing **container** (not VM — VFIO is rejected by GB10 firmware).
The install pulls **multi-GB CUDA 13.x wheels** on aarch64; run detached + poll.

```bash
VM=lab-004-vllm
lab/scripts/lab.sh exec $VM "apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3-pip python3-venv python3-dev build-essential"
lab/scripts/lab.sh exec $VM "su - lab -c 'python3 -m venv ~/.venv'"
# detached install (heavy)
lab/scripts/lab.sh exec $VM \
  "su - lab -c 'setsid bash -c \"~/.venv/bin/pip install vllm > /tmp/vllm-install.log 2>&1\" </dev/null >/dev/null 2>&1 & echo launched'"
# poll: until [ -x ~lab/.venv/bin/vllm ]

# launch server (detached). --gpu-memory-utilization must reflect the CONTAINER's
# memory limit (32 GiB here -> 0.20 of GB10's 121 GiB = 24 GiB; fits).
lab/scripts/lab.sh exec $VM \
  "su - lab -c 'setsid bash -c \"~/.venv/bin/vllm serve Qwen/Qwen3-8B --host 0.0.0.0 --port 8000 --gpu-memory-utilization 0.20 --max-model-len 8192 > /tmp/vllm-serve.log 2>&1\" </dev/null >/dev/null 2>&1 & echo launched'"
# poll: until `curl -fs localhost:8000/v1/models` returns 200
```

Acceptance: `/v1/models` lists the model; `/v1/chat/completions` returns text.

## Caveats

- **GPU:** without LXD GPU passthrough the stack runs CPU-only. Pick small models for
  tests. GPU passthrough is a separate (future) building block.
- **Disk:** model weights are large — size the VM's root disk accordingly (`LAB_DISK`).
- **Firewall:** cross-VM reachability still depends on the host not dropping `lxdbr0`
  forwarding (Docker `DOCKER-USER` fix).
