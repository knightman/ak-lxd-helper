# 003 — Open WebUI ↔ Ollama (two VMs working together)

- **Status:** ⚪ planned (spec stub — execute in a later pass)
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

- [ ] Open WebUI service is up and reachable.
- [ ] From `lab-003-openwebui`: `curl http://<ollama-ip>:11434/api/tags` lists the model.
- [ ] Open WebUI lists the Ollama model and returns a chat completion end-to-end.

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

_(pending)_
