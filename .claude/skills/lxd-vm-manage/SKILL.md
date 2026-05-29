---
name: lxd-vm-manage
description: Operate and maintain an EXISTING LXD instance via the ak-lxd-helper API / lab.sh — lifecycle (start/stop/restart), snapshots (create/list/restore/delete), attach/detach devices, package update/install, LAN SSH exposure, and delete. Use for day-to-day management of a VM created by lxd-vm-create (the operate complement to create/provision/connect).
---

# lxd-vm-manage

Day-to-day management of an existing instance. All operations go through the helper
(`lab/scripts/lab.sh`, which calls the dashboard API). Replace `<vm>` with the
instance name.

## Prerequisites

- Dashboard server running and reaching the LXD socket.
- For in-guest operations (packages) the instance must be running and have the
  lxd-agent (cloud-image VMs do).

## Operations

### Lifecycle
```bash
lab/scripts/lab.sh start   <vm>
lab/scripts/lab.sh stop    <vm>        # force stop
lab/scripts/lab.sh restart <vm>
```

### Snapshots
```bash
lab/scripts/lab.sh snapshot <vm> <snap>   # create (filesystem-only by default)
lab/scripts/lab.sh snapshots <vm>         # list
lab/scripts/lab.sh restore  <vm> <snap>   # roll back to a snapshot
lab/scripts/lab.sh snap-rm  <vm> <snap>   # delete a snapshot
```
Take a snapshot before risky changes (package upgrades, config edits) so you can
`restore`.

### Packages (runs as root in the guest, via exec)
```bash
lab/scripts/lab.sh pkg <vm> update                 # apt-get update
lab/scripts/lab.sh pkg <vm> install git htop tmux  # install packages
lab/scripts/lab.sh pkg <vm> upgrade                # apt-get upgrade (can be slow — see reference)
```

### Devices (attach/detach)
```bash
lab/scripts/lab.sh device-add <vm> <dev> <type> key=val ...   # e.g. disk pool=default source=myvol
lab/scripts/lab.sh device-rm  <vm> <dev>
```

### LAN SSH
```bash
lab/scripts/lab.sh expose-lan <vm>     # give an existing VM a LAN IP + password SSH (see lxd-vm-create)
```

### Delete (irreversible)
```bash
lab/scripts/lab.sh delete <vm>         # stop + delete the instance (alias: teardown)
```

## Direct API (if not using lab.sh)

`POST /api/instances/{name}/state` · `…/snapshots` (GET/POST) ·
`POST …/snapshots/restore` · `DELETE …/snapshots/{snap}` ·
`POST/DELETE …/devices[/{dev}]` · `POST …/exec` · `DELETE /api/instances/{name}`.

See `reference.md` for gotchas (stateful snapshots, VM device hot-plug, slow upgrades,
delete safety).
