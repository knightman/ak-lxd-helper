# 004 — vLLM serving Qwen3-VL-30B-A3B (FP8) on GB10

- **Status:** 🟢 done (2026-06-02) · **v2 2026-06-03**: upgraded Qwen3-8B → **Qwen3-VL-30B-A3B-Instruct-FP8** (multimodal)
- **Skills:** `lxd-vm-create` (container variant), `lxd-vm-provision`
- **Instance:** `lab-004-vllm` (**LXD container**, not VM)

## Goal

Run a self-hosted OpenAI-compatible LLM server (vLLM) using the host's NVIDIA **GB10**
GPU, so other lab VMs can use it as a model backend.

## Why container, not VM

The spec originally targeted a VM with VFIO GPU passthrough. We proved that
**GPU passthrough is rejected by the GB10 firmware** with
`vfio-pci 000f:01:00.0: Firmware has requested this device have a 1:1 IOMMU
mapping, rejecting configuring the device without a 1:1 mapping. Contact your
platform vendor.` — Grace-Blackwell's coherent unified-memory model requires the
GPU to operate with an identity (1:1) IOMMU mapping, which VFIO can't satisfy.

NVIDIA's expected path on Grace-Blackwell is the **NVIDIA Container Toolkit**: an
LXD container with `gpu` device + `nvidia.runtime=true` shares the host driver
directly. That's what this spec uses.

## Inputs / parameters

| Name | Value | Notes |
|------|-------|-------|
| profile | `base-ubuntu,gpu-share` | stacked: base prereqs + GPU/100 GB disk/32 GB RAM |
| model | `Qwen/Qwen3-8B` | smaller-first validation (BF16, ~16 GB weights) |
| GPU device | `gpu0` (type `physical`) | shares host GB10 via NVIDIA Container Toolkit |
| `--gpu-memory-utilization` | `0.20` | GB10 unified memory is the host's; cap at 24 GiB |
| `--max-model-len` | `8192` | reduces KV cache footprint |

## Preconditions

- Host has the NVIDIA driver (verified by `nvidia-smi` on the host).
- `nvidia-container-toolkit` (`nvidia-container-cli`) is installed on the host.
- LXD reports `nvidia_runtime` and `gpu_devices` capabilities.
- Host `iptables` Docker FORWARD fix is applied + persisted (else cloud-init's apt
  step and `pip install` fail; persist with `iptables-persistent` + `netfilter-persistent save`).

## Steps

1. Create `gpu-share` profile (PUT `/api/profiles/gpu-share`) with `nvidia.runtime=true`,
   the `gpu` device, 100 GiB root, 32 GiB RAM, 6 CPUs.
2. `lab.sh create-container lab-004-vllm base-ubuntu,gpu-share`.
3. Inside: `apt install python3-pip python3-venv build-essential` (cloud-init's apt
   step may need re-running after the network metric fix).
4. `python3 -m venv ~/.venv && ~/.venv/bin/pip install vllm` (detached + poll;
   pulls **multi-GB CUDA 13.x wheels** for aarch64 — minutes to ~30 minutes).
5. `vllm serve Qwen/Qwen3-8B --host 0.0.0.0 --port 8000 --gpu-memory-utilization 0.20 --max-model-len 8192 --enable-auto-tool-choice --tool-call-parser hermes`
   (first run pulls ~16 GB model from HF). The two tool-calling flags are
   **required** for any OpenAI tool/function calling (e.g. pi's web_search); without
   them vLLM returns `400 "auto" tool choice requires --enable-auto-tool-choice and
   --tool-call-parser to be set`. `hermes` is the right parser for Qwen2.5/Qwen3
   (their chat templates ship Hermes-style tool use).
6. Run it under a **systemd unit** (`lab/units/vllm.service` → push to
   `/etc/systemd/system/vllm.service`, `User=lab`, `WantedBy=multi-user.target`) so it
   survives container reboots and auto-restarts — replaces the original detached
   `bash -c` launch. (Added 2026-06-03.)

## Acceptance criteria

- [x] `nvidia-smi` inside the container shows the GB10 with driver `580.x`.
- [x] vllm 0.22.0 installed in the venv; `vllm --version` works.
- [x] `vllm serve` reaches "Application startup complete" + `GET /v1/models 200`.
- [x] `/v1/models` lists `Qwen/Qwen3-8B`.
- [x] `/v1/chat/completions` returns a real completion with `usage.completion_tokens > 0`.
- [x] Reachable from other lab instances on `lxdbr0`.

## Verification

```bash
lab/tests/lab-004-005.sh
```

## Teardown

```bash
lab/scripts/lab.sh delete lab-004-vllm
```

## Results

**2026-06-02 — PASS.** lab-004-vllm container running with the GB10 shared via
`nvidia.runtime=true`. vLLM 0.22.0 (torch 2.11.0 + nvidia-cuda-* 13.x) installed in
a venv after a fresh apt + Python pip path; serves Qwen3-8B on `0.0.0.0:8000`.
`/v1/models` lists the model; `/v1/chat/completions` returns text (Qwen3 emits
`<think>` reasoning blocks then a final answer). Bridge IP for cross-VM: **10.10.249.171**.

Lessons folded into the framework (see Phase-5 diff):
- VM GPU passthrough rejected by GB10 firmware → container path is canonical.
- Docker `FORWARD DROP` rules **must be persisted** with `iptables-persistent` to survive reboot.
- `lab-lan-up.sh` regex `^en` missed container `eth*` names; updated to `^(en|eth)`,
  plus a netplan `dhcp4-overrides.route-metric: 50` so the LAN NIC wins as default
  route (both VMs and containers had two equal-metric defaults → outbound stuck on lxdbr0).
- `--gpu-memory-utilization` must reflect the container's memory cap, not the GPU's
  unified-memory total (GB10 reports 121 GiB but container limit was 32 GiB).

### v2 — Qwen3-VL-30B-A3B-Instruct-FP8 (2026-06-03 — PASS)

Upgraded the served model from Qwen3-8B to **`Qwen/Qwen3-VL-30B-A3B-Instruct-FP8`**
(official FP8, ~31 GB, MoE 3B-active, multimodal) for agentic coding + tool calling +
image→text. Unit in `lab/units/vllm.service`; verified by `lab/tests/lab-004-005.sh`
(14/14), incl. a vision check (model reads a red image) and tool-calling.

Config deltas vs v1 (all in the systemd unit):
- `--gpu-memory-utilization 0.50` (≈60 GiB of the 121 GiB unified pool — the flag is a
  fraction of the **full** pool, not the container cap; v1's 0.20 ≈ 24 GiB held the 8B),
  `--max-model-len 131072`, `--max-num-seqs 4` (bandwidth-bound above ~4 streams).
- Container `limits.memory` raised 32 GiB → **100 GiB** (`lxc config set lab-004-vllm
  limits.memory 100GiB`).
- `--tool-call-parser hermes` (Qwen3-VL-Instruct emits hermes-style `<tool_call>`
  blocks; `qwen3_coder` leaves them unparsed in `content`).
- `Environment=VLLM_USE_FLASHINFER_SAMPLER=0` — FlashInfer's top-k sampler JIT-compiles
  at startup and needs the CUDA toolkit (`nvcc`/`/usr/local/cuda`), absent in this
  runtime-only container; the native sampler avoids it. (v1/8B never hit that path.)
- vLLM 0.22.0 already supports the `Qwen3VLMoeForConditionalGeneration` arch — no upgrade.
- Vision images fetched from external URLs can 429 (e.g. Wikimedia); embed as base64
  `data:` URIs for reliable testing.
- Snapshot `pre-vl-30b` taken before the swap for rollback.
