# 003 — Open WebUI ↔ Ollama (two VMs working together)

- **Status:** 🟢 done (2026-05-28)
- **Skills:** `lxd-vm-create`, `lxd-vm-provision`, `lxd-multi-connect`
- **Instances:** `lab-003-openwebui` + `lab-002-ollama` (from project 002)

## Goal

Stand up a fresh VM running Open WebUI and connect it to the existing Ollama VM so the
two function together: the WebUI talks to Ollama's API over `lxdbr0` and can chat with
the pulled model. Proves the `lxd-multi-connect` building block (multi-VM wiring).

## Inputs / parameters

| Name | Default | Notes |
|------|---------|-------|
| webui stack | open-webui | install via pip/docker per its guide |
| ollama instance | `lab-002-ollama` | dependency (must be running) |
| link | `OLLAMA_BASE_URL=http://<ollama-ip>:11434` | discovered at runtime |

## Preconditions

- Project 002 (`lab-002-ollama`) is running and serving on `0.0.0.0:11434`.

## Steps

1. `lxd-vm-create lab-003-openwebui`.
2. `lxd-vm-provision` Open WebUI on it.
3. `lxd-multi-connect lab-003-openwebui lab-002-ollama` — discover the Ollama VM's
   `lxdbr0` IP, set `OLLAMA_BASE_URL`, restart Open WebUI, verify reachability.

## Acceptance criteria

- [x] Open WebUI service is up and reachable (`/health` = `{"status":true}`, listens `0.0.0.0:8080`).
- [x] From `lab-003-openwebui`: `curl http://<ollama-ip>:11434/api/*` reaches Ollama (cross-VM over lxdbr0).
- [x] Open WebUI lists the Ollama model (`/api/models` → `llama3.2:1b`) and returns a completion
  end-to-end (proxied via `/ollama/api/generate` → Ollama VM).

## Verification

```bash
OLLAMA_IP=$(lab/scripts/lab.sh ip lab-002-ollama)
lab/scripts/lab.sh exec lab-003-openwebui "curl -s http://$OLLAMA_IP:11434/api/tags"
```

## Teardown

```bash
lab/scripts/lab.sh teardown lab-003-openwebui
# leave lab-002-ollama unless also tearing down 002
```

## Results

**2026-05-28 — PASS.** `lab-003-openwebui` created from `base-ubuntu`, then:

- Made a `conda` env `owui` (Python 3.11), installed **CPU-only PyTorch first**
  (`--index-url https://download.pytorch.org/whl/cpu`) then `pip install open-webui`
  → **open-webui 0.9.5**, `torch 2.12.0+cpu`. *(Critical: installing open-webui
  directly pulled multi-GB `nvidia_*` CUDA wheels on this arm64/GB10 host — pre-installing
  CPU torch avoids that.)*
- systemd unit runs `open-webui serve --host 0.0.0.0 --port 8080` with
  `OLLAMA_BASE_URL=http://10.10.249.8:11434`. Service **active**, `LISTEN 0.0.0.0:8080`.
- **Multi-connect (`lxd-multi-connect`):** discovered Ollama IP `10.10.249.8` at runtime;
  `lab-003` reaches `http://10.10.249.8:11434/api/version` and `/api/generate` over lxdbr0.
- **End-to-end through Open WebUI:** created an admin via `/api/v1/auths/signup`
  (token); `GET /api/models` lists `llama3.2:1b` (Open WebUI's backend connected to the
  Ollama VM); `POST /ollama/api/generate` returned a real completion proxied to the
  Ollama VM.

Notes:
- Open WebUI's native `/api/chat/completions` 400s on a brand-new instance
  (`'NoneType' ... startswith` in `process_chat` — needs UI-side config/default model).
  The `/ollama/api/*` proxy and the browser UI work; that endpoint is a fresh-instance quirk.
- `WEBUI_AUTH=False` did **not** open the REST API unauthenticated (proxy still returned
  "Not authenticated"); the signup-token flow is the reliable automated path.
- Test admin: `lab@lab.local` / `labpass123` (throwaway). Open the UI at the VM's
  `:8080` to chat interactively.
