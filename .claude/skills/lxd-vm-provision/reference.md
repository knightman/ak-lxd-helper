# lxd-vm-provision — reference

## General principles

- **Guide-driven, not memory-driven.** Always fetch the current official install
  guide/repo and follow its steps; record the exact commands you ran in the spec.
- **Idempotent.** Guard steps so re-running is safe (`test -x … || install`).
- **exec runs as root** in the VM (no `sudo` needed). Long installs may exceed the
  exec operation timeout — split into steps or run in the background and poll.
- **Reachability.** For services other VMs will consume, bind to `0.0.0.0` and confirm
  the listening socket (`ss -ltnp`).

## Example: Ollama (lab project 002)

```bash
# install
lab/scripts/lab.sh exec lab-002-ollama "curl -fsSL https://ollama.com/install.sh | sh"
# bind to all interfaces (so project 003's Open WebUI VM can reach it)
lab/scripts/lab.sh exec lab-002-ollama \
  "mkdir -p /etc/systemd/system/ollama.service.d && \
   printf '[Service]\nEnvironment=OLLAMA_HOST=0.0.0.0:11434\n' \
     > /etc/systemd/system/ollama.service.d/host.conf && \
   systemctl daemon-reload && systemctl restart ollama"
# pull a small model + smoke test
lab/scripts/lab.sh exec lab-002-ollama "ollama pull llama3.2:1b"
lab/scripts/lab.sh exec lab-002-ollama "curl -s localhost:11434/api/tags"
```

Acceptance: `ollama --version` works, service active, `/api/tags` lists the model, a
`/api/generate` call returns text, and the port listens on `0.0.0.0`.

## Caveats

- **GPU:** without LXD GPU passthrough the stack runs CPU-only. Pick small models for
  tests. GPU passthrough is a separate (future) building block.
- **Disk:** model weights are large — size the VM's root disk accordingly (`LAB_DISK`).
- **Firewall:** cross-VM reachability still depends on the host not dropping `lxdbr0`
  forwarding (Docker `DOCKER-USER` fix).
