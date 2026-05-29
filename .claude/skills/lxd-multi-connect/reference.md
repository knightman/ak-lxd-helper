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

## Example: Open WebUI ↔ Ollama (lab project 003)

```bash
OLLAMA_IP=$(lab/scripts/lab.sh ip lab-002-ollama)
# raw reachability
lab/scripts/lab.sh exec lab-003-openwebui "curl -s http://$OLLAMA_IP:11434/api/tags"
# point Open WebUI at Ollama (exact mechanism depends on how Open WebUI was installed)
lab/scripts/lab.sh exec lab-003-openwebui \
  "echo OLLAMA_BASE_URL=http://$OLLAMA_IP:11434 >> /etc/open-webui.env && systemctl restart open-webui"
```

Acceptance: Open WebUI is up, lists the Ollama model, and returns a chat completion
end-to-end.

## Notes

- Prefer **IP discovery at runtime** (`lab.sh ip`) over hardcoding — DHCP leases change.
- For a stable address, you could later assign a static `ipv4.address` on the NIC
  device or add a DNS name; out of scope for the first pass.
- Keep the service VM (`lab-002-ollama`) running while the client is connected.
