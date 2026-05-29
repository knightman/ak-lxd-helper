# 002 — LLM serving (Ollama) on a VM

- **Status:** ⚪ planned (spec stub — execute in a later pass)
- **Skills:** `lxd-vm-create`, `lxd-vm-provision`
- **Instance:** `lab-002-ollama`

## Goal

On an Ubuntu base VM, install and run a local LLM server (Ollama) from its official
install guide, pull a small model, and confirm the API serves a completion. Proves the
`lxd-vm-provision` building block against a real stack.

## Inputs / parameters

| Name | Default | Notes |
|------|---------|-------|
| base | project 001 | reuse the `base-ubuntu` profile |
| stack | ollama | install via https://ollama.com/install.sh |
| model | `llama3.2:1b` | small, fast to pull/test |
| port | 11434 | bind `0.0.0.0` so other VMs can reach it (see 003) |

## Preconditions

- Project 001's base build works (network + prereqs).
- (GPU note: Ollama runs CPU-only unless GPU passthrough is configured — out of scope.)

## Steps

1. `lxd-vm-create lab-002-ollama`.
2. `lxd-vm-provision` with the Ollama install guide: run `install.sh`, set
   `OLLAMA_HOST=0.0.0.0:11434` (systemd override), enable the service.
3. `ollama pull <model>`; smoke-test `/api/generate`.

## Acceptance criteria

- [ ] `ollama --version` works; `ollama` systemd service active.
- [ ] `curl http://localhost:11434/api/tags` lists the pulled model.
- [ ] A `/api/generate` call returns a non-empty completion.
- [ ] Service listens on `0.0.0.0:11434` (reachable from another VM).

## Verification

```bash
lab/scripts/lab.sh exec lab-002-ollama "ollama --version"
lab/scripts/lab.sh exec lab-002-ollama "curl -s localhost:11434/api/tags"
```

## Teardown

```bash
lab/scripts/lab.sh teardown lab-002-ollama
```

## Results

_(pending)_
