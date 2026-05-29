# lxd-vm-manage — reference

## Gotchas

- **Snapshots are filesystem-only by default.** `snapshot` takes a disk snapshot;
  running-VM memory/state is NOT captured unless the instance has
  `migration.stateful=true` and you pass `stateful`. For a clean rollback point,
  snapshot while stopped, or accept that in-flight state isn't preserved.
- **`restore` reverts the disk.** Anything written since the snapshot is lost — it's
  the point, but don't restore over work you want to keep. Restore is async; the
  helper waits for it.
- **Device hot-plug on VMs is limited.** Some device changes (disks, NICs) attach to a
  running VM, but others only take effect after a `restart`. If a freshly attached
  device doesn't appear in the guest, restart the VM. (The `eth1` macvlan NIC added by
  `expose-lan` needs the guest to DHCP it — `expose-lan` handles that.)
- **Packages need network + run as root.** `pkg`/`exec` reach apt mirrors only if the
  host's Docker `DOCKER-USER` forwarding fix is in place (see repo README → Networking).
- **Big upgrades exceed the exec timeout.** `pkg upgrade` / large `pkg install` can run
  longer than the helper's 300s exec window. For those, run detached and poll (same
  pattern as `lxd-vm-provision`):
  ```bash
  lab/scripts/lab.sh exec <vm> "setsid bash -c 'DEBIAN_FRONTEND=noninteractive apt-get -y upgrade > /var/log/upgrade.log 2>&1' </dev/null >/dev/null 2>&1 & echo launched"
  # then poll: lab/scripts/lab.sh exec <vm> "tail -1 /var/log/upgrade.log"
  ```
- **Delete is irreversible.** `delete`/`teardown` force-stops then removes the instance
  and its root disk. Snapshot or copy anything you need first. Custom storage volumes
  (e.g. uploaded ISOs) are separate — remove with `DELETE /api/storage/{pool}/volumes/{name}`.

## Examples

```bash
# safe upgrade: snapshot, upgrade, roll back if it breaks
lab/scripts/lab.sh snapshot lab-002-ollama pre-upgrade
lab/scripts/lab.sh pkg lab-002-ollama upgrade
# ...if something broke:
lab/scripts/lab.sh restore lab-002-ollama pre-upgrade

# attach an extra data disk volume, then detach
lab/scripts/lab.sh device-add lab-001-ubuntu-base data disk pool=default source=myvol path=/data
lab/scripts/lab.sh device-rm  lab-001-ubuntu-base data
```

## API mapping

| lab.sh | API |
|--------|-----|
| start/stop/restart | `POST /api/instances/{name}/state {action,force}` |
| snapshots / snapshot | `GET` / `POST /api/instances/{name}/snapshots` |
| restore | `POST /api/instances/{name}/snapshots/restore {name}` |
| snap-rm | `DELETE /api/instances/{name}/snapshots/{snap}` |
| pkg | `POST /api/instances/{name}/exec {command}` |
| device-add / device-rm | `POST` / `DELETE /api/instances/{name}/devices[/{dev}]` |
| delete / teardown | `DELETE /api/instances/{name}` |
