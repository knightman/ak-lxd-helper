---
name: lxd-multi-connect
description: Wire two LXD instances together so they function as one system (e.g. connect an Open WebUI VM to an existing Ollama VM). Discovers the target's lxdbr0 IP, configures the client's connection settings, and verifies end-to-end reachability via the ak-lxd-helper API. Powers lab project 003.
---

# lxd-multi-connect

Connect a client instance to a service instance over the LXD bridge (`lxdbr0`) and
prove they work together end-to-end. Canonical example: Open WebUI → Ollama (lab
project 003).

> Status: building block; full worked example is lab project 003 (deferred run).

## When to use

- A spec composes two (or more) VMs that must talk to each other — one provides a
  service, another consumes it.

## Prerequisites

- Both instances exist and are Running; the service VM was provisioned
  (`lxd-vm-provision`) and binds its port to `0.0.0.0`.
- They share `lxdbr0` (default for `base-ubuntu`), so they're on the same subnet.

## Workflow

1. **Discover the service IP** on the bridge:
   ```bash
   SERVICE_IP=$(lab/scripts/lab.sh ip <service-vm>)
   ```
2. **Verify raw reachability** from the client before app config:
   ```bash
   lab/scripts/lab.sh exec <client-vm> "curl -s http://$SERVICE_IP:<port>/<health>"
   ```
   If this fails, it's networking (service not on `0.0.0.0`, or host `lxdbr0`
   forwarding dropped) — fix that before touching app config.
3. **Configure the client** with the discovered endpoint (env var / config file) and
   restart it. Example for Open WebUI → Ollama:
   ```bash
   lab/scripts/lab.sh exec <client-vm> \
     "echo OLLAMA_BASE_URL=http://$SERVICE_IP:11434 >> /etc/<app>.env && systemctl restart <app>"
   ```
4. **Verify end-to-end** against the spec: the client lists the service's resources
   (e.g. models) and completes a real request (e.g. a chat completion).
5. **Record** the discovered IP, config applied, and the end-to-end result in the spec.

## Success criteria

The client reaches the service over `lxdbr0` AND a full application-level round trip
succeeds (per the spec's acceptance criteria).

See `reference.md` for the Open WebUI ↔ Ollama specifics and failure isolation.
