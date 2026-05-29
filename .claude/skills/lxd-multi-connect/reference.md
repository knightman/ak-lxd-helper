# lxd-multi-connect — reference

## Failure isolation (do this in order)

1. **Service binding** — on the service VM: `ss -ltnp | grep <port>` should show
   `0.0.0.0:<port>` (not `127.0.0.1`). If it's loopback-only, other VMs can't reach it.
2. **Bridge reachability** — from the client VM: `curl http://<service-ip>:<port>/...`.
   Failure here is networking, not the app:
   - both VMs on `lxdbr0`? (`lab.sh ip` returns a `10.x` bridge address for each)
   - host not dropping `lxdbr0` forwarding (Docker `DOCKER-USER` fix).
3. **App config** — only after 1–2 pass, set the client's endpoint and restart.
4. **End-to-end** — the application-level request (chat completion, etc.).

## Example: Open WebUI ↔ Ollama (lab project 003 — verified 2026-05-28)

Install Open WebUI (`lxd-vm-provision`) into a conda **py3.11** env, then run it as a
service pointed at the Ollama VM:

```bash
OLLAMA_IP=$(lab/scripts/lab.sh ip lab-002-ollama)          # discover at runtime
# raw cross-VM reachability FIRST (proves networking before app config)
lab/scripts/lab.sh exec lab-003-openwebui "curl -s http://$OLLAMA_IP:11434/api/version"
# systemd unit runs: open-webui serve --host 0.0.0.0 --port 8080
#   with Environment=OLLAMA_BASE_URL=http://$OLLAMA_IP:11434
```

Verify end-to-end through Open WebUI (its API needs auth — create the first admin):

```bash
TOK=$(lab/scripts/lab.sh exec lab-003-openwebui \
  "curl -s localhost:8080/api/v1/auths/signup -H 'content-type: application/json' \
   -d '{\"name\":\"lab\",\"email\":\"lab@lab.local\",\"password\":\"labpass123\"}'" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
# model list proves Open WebUI's backend reached Ollama:
lab/scripts/lab.sh exec lab-003-openwebui "curl -s localhost:8080/api/models -H 'Authorization: Bearer $TOK'"
# completion proxied through Open WebUI -> Ollama VM:
lab/scripts/lab.sh exec lab-003-openwebui \
  "curl -s localhost:8080/ollama/api/generate -H 'Authorization: Bearer $TOK' \
   -d '{\"model\":\"llama3.2:1b\",\"prompt\":\"hi\",\"stream\":false}'"
```

### Gotchas (learned)

- **CPU torch first.** `pip install open-webui` on arm64 pulls multi-GB `nvidia_*` CUDA
  wheels. Pre-install CPU torch: `pip install torch --index-url https://download.pytorch.org/whl/cpu`.
- **Auth is required for Open WebUI's REST API.** `WEBUI_AUTH=False` does NOT open it;
  use the `/api/v1/auths/signup` token flow above for automated checks.
- **`/api/chat/completions` 400s on a brand-new instance** (`'NoneType'...startswith`);
  use `/ollama/api/*` proxy or the browser UI for chat.

## Notes

- Prefer **IP discovery at runtime** (`lab.sh ip`) over hardcoding — DHCP leases change.
- For a stable address, you could later assign a static `ipv4.address` on the NIC
  device or add a DNS name; out of scope for the first pass.
- Keep the service VM (`lab-002-ollama`) running while the client is connected.
