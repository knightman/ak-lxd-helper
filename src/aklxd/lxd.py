"""Async client for the LXD REST API over a local Unix socket.

LXD exposes the same REST API on its Unix socket that it does over TLS, so we
talk to it with plain HTTP (no certificates). Many mutating calls return
*background operations*; helpers here wait for those to finish and surface
errors as :class:`LXDError`.

API reference: https://documentation.ubuntu.com/lxd/en/latest/api/
"""

from __future__ import annotations

import os

import aiohttp

# Unix sockets ignore the host part of the URL; "lxd" is just a placeholder.
BASE = "http://lxd"


class LXDError(Exception):
    """Raised when LXD returns an error response or an operation fails."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class LXDClient:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self._session: aiohttp.ClientSession | None = None

    async def connect(self) -> None:
        if self._session is None or self._session.closed:
            connector = aiohttp.UnixConnector(path=self.socket_path)
            self._session = aiohttp.ClientSession(connector=connector)

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()
        self._session = None

    async def __aenter__(self) -> "LXDClient":
        await self.connect()
        return self

    async def __aexit__(self, *_exc) -> None:
        await self.close()

    # -- low level ---------------------------------------------------------

    async def _request(self, method: str, path: str, data=None, raw: bool = False):
        await self.connect()
        assert self._session is not None
        kwargs = {"json": data} if data is not None else {}
        async with self._session.request(method, BASE + path, **kwargs) as resp:
            if raw:
                return await resp.read()
            body = await resp.json()
        if isinstance(body, dict) and body.get("type") == "error":
            raise LXDError(body.get("error", "unknown error"), body.get("error_code"))
        return body

    async def get(self, path: str, raw: bool = False):
        return await self._request("GET", path, raw=raw)

    async def _meta(self, path: str):
        return (await self.get(path)).get("metadata", {})

    async def wait_operation(self, response: dict, timeout: int = 120) -> dict:
        """Block until an async operation completes; return the operation object."""
        op = response.get("operation")
        if not op:  # synchronous response — nothing to wait on
            return response.get("metadata", {})
        result = await self._request("GET", f"{op}/wait?timeout={timeout}")
        operation = result.get("metadata", {})
        if operation.get("status") == "Failure":
            raise LXDError(operation.get("err", "operation failed"))
        return operation

    async def operation_websocket(self, op: str, secret: str) -> aiohttp.ClientWebSocketResponse:
        """Open a websocket to an operation's file descriptor (exec/console streams)."""
        await self.connect()
        assert self._session is not None
        return await self._session.ws_connect(f"{BASE}{op}/websocket?secret={secret}")

    # -- server ------------------------------------------------------------

    async def server_info(self) -> dict:
        return await self._meta("/1.0")

    async def resources(self) -> dict:
        return await self._meta("/1.0/resources")

    # -- instances ---------------------------------------------------------

    async def list_instances(self) -> list:
        return await self._meta("/1.0/instances?recursion=2")

    async def get_instance(self, name: str) -> dict:
        return await self._meta(f"/1.0/instances/{name}")

    async def instance_state(self, name: str) -> dict:
        return await self._meta(f"/1.0/instances/{name}/state")

    async def set_instance_state(self, name: str, action: str, force: bool = False,
                                 timeout: int = 60) -> dict:
        body = {"action": action, "force": force, "timeout": timeout}
        resp = await self._request("PUT", f"/1.0/instances/{name}/state", data=body)
        return await self.wait_operation(resp, timeout=timeout + 30)

    async def update_instance(self, name: str, config: dict) -> dict:
        # PATCH merges config; PUT would replace the whole record. LXD returns
        # an async operation for config changes — wait for it so callers see the
        # change applied before re-reading the instance.
        resp = await self._request("PATCH", f"/1.0/instances/{name}", data=config)
        return await self.wait_operation(resp)

    async def rename_instance(self, name: str, new_name: str) -> dict:
        resp = await self._request("POST", f"/1.0/instances/{name}", data={"name": new_name})
        return await self.wait_operation(resp)

    async def delete_instance(self, name: str) -> dict:
        resp = await self._request("DELETE", f"/1.0/instances/{name}")
        return await self.wait_operation(resp)

    async def create_instance(self, payload: dict) -> dict:
        """Create an instance from a simplified payload (see server.py)."""
        body = self._build_create_body(payload)
        resp = await self._request("POST", "/1.0/instances", data=body)
        return await self.wait_operation(resp, timeout=600)

    @staticmethod
    def _build_create_body(p: dict) -> dict:
        image = p.get("image", {})
        if p.get("empty") or (not image):  # empty VM (e.g. to install from an ISO)
            source = {"type": "none"}
        elif image.get("server"):  # pull from a remote simplestreams/lxd server
            source = {
                "type": "image",
                "mode": "pull",
                "server": image["server"],
                "protocol": image.get("protocol", "simplestreams"),
                "alias": image.get("alias"),
            }
            if image.get("image_type"):  # force "container" or "virtual-machine" variant
                source["image_type"] = image["image_type"]
        elif image.get("fingerprint"):
            source = {"type": "image", "fingerprint": image["fingerprint"]}
        else:  # local alias
            source = {"type": "image", "alias": image.get("alias")}
        body = {
            "name": p["name"],
            "type": p.get("type", "container"),
            "source": source,
            "config": p.get("config", {}),
            "profiles": p.get("profiles", ["default"]),
        }
        if p.get("devices"):
            body["devices"] = p["devices"]
        if p.get("start"):
            body["start"] = True
        return body

    # -- exec --------------------------------------------------------------

    async def exec_command(self, name: str, command, environment=None,
                           cwd: str | None = None, user: int | None = None) -> dict:
        """Run a non-interactive command and capture stdout/stderr/return code."""
        if isinstance(command, str):
            command = ["/bin/sh", "-c", command]
        body = {
            "command": command,
            "wait-for-websocket": False,
            "interactive": False,
            "record-output": True,
        }
        if environment:
            body["environment"] = environment
        if cwd:
            body["cwd"] = cwd
        if user is not None:
            body["user"] = user
        resp = await self._request("POST", f"/1.0/instances/{name}/exec", data=body)
        op = await self.wait_operation(resp, timeout=300)
        meta = op.get("metadata", {}) or {}
        output = meta.get("output", {}) or {}
        result = {
            "return": meta.get("return"),
            "stdout": await self._read_log(output.get("1")),
            "stderr": await self._read_log(output.get("2")),
        }
        # Clean up the recorded log files.
        for path in (output.get("1"), output.get("2")):
            if path:
                try:
                    await self._request("DELETE", path)
                except LXDError:
                    pass
        return result

    async def _read_log(self, path: str | None) -> str:
        if not path:
            return ""
        data = await self.get(path, raw=True)
        return data.decode("utf-8", errors="replace") if isinstance(data, bytes) else str(data)

    async def exec_interactive(self, name: str, command, width: int = 80, height: int = 24,
                               environment=None):
        """Create an interactive exec operation; return (op_path, fds_secrets)."""
        body = {
            "command": command,
            "wait-for-websocket": True,
            "interactive": True,
            "width": width,
            "height": height,
        }
        if environment:
            body["environment"] = environment
        resp = await self._request("POST", f"/1.0/instances/{name}/exec", data=body)
        op = resp.get("operation")
        fds = resp.get("metadata", {}).get("metadata", {}).get("fds", {})
        return op, fds

    async def console(self, name: str, width: int = 80, height: int = 24):
        """Attach to an instance console; return (op_path, fds_secrets)."""
        body = {"width": width, "height": height, "type": "console"}
        resp = await self._request("POST", f"/1.0/instances/{name}/console", data=body)
        op = resp.get("operation")
        fds = resp.get("metadata", {}).get("metadata", {}).get("fds", {})
        return op, fds

    # -- images ------------------------------------------------------------

    async def list_images(self) -> list:
        return await self._meta("/1.0/images?recursion=1")

    async def get_image(self, fingerprint: str) -> dict:
        return await self._meta(f"/1.0/images/{fingerprint}")

    async def update_image(self, fingerprint: str, props: dict) -> dict:
        return await self._request("PATCH", f"/1.0/images/{fingerprint}", data=props)

    async def delete_image(self, fingerprint: str) -> dict:
        resp = await self._request("DELETE", f"/1.0/images/{fingerprint}")
        return await self.wait_operation(resp)

    async def add_image_alias(self, fingerprint: str, name: str, description: str = "") -> dict:
        body = {"name": name, "target": fingerprint, "description": description}
        return await self._request("POST", "/1.0/images/aliases", data=body)

    async def delete_image_alias(self, name: str) -> dict:
        return await self._request("DELETE", f"/1.0/images/aliases/{name}")

    async def import_image(self, server: str, alias: str, protocol: str = "simplestreams",
                           alias_local: str | None = None, image_type: str | None = None) -> dict:
        source = {
            "type": "image",
            "mode": "pull",
            "server": server,
            "protocol": protocol,
            "alias": alias,
        }
        if image_type:
            source["image_type"] = image_type  # "container" or "virtual-machine"
        body = {"source": source}
        if alias_local:
            body["aliases"] = [{"name": alias_local}]
        resp = await self._request("POST", "/1.0/images", data=body)
        return await self.wait_operation(resp, timeout=900)

    # -- snapshots ---------------------------------------------------------

    async def list_snapshots(self, name: str) -> list:
        return await self._meta(f"/1.0/instances/{name}/snapshots?recursion=1")

    async def create_snapshot(self, name: str, snapshot: str, stateful: bool = False) -> dict:
        resp = await self._request("POST", f"/1.0/instances/{name}/snapshots",
                                   data={"name": snapshot, "stateful": stateful})
        return await self.wait_operation(resp, timeout=300)

    async def restore_snapshot(self, name: str, snapshot: str) -> dict:
        resp = await self._request("PUT", f"/1.0/instances/{name}", data={"restore": snapshot})
        return await self.wait_operation(resp, timeout=300)

    async def delete_snapshot(self, name: str, snapshot: str) -> dict:
        resp = await self._request("DELETE", f"/1.0/instances/{name}/snapshots/{snapshot}")
        return await self.wait_operation(resp)

    # -- logs --------------------------------------------------------------

    async def list_logs(self, name: str) -> list:
        """List host-side log file paths for an instance (e.g. qemu.log)."""
        return await self._meta(f"/1.0/instances/{name}/logs")

    async def get_log_file(self, name: str, filename: str) -> str:
        data = await self.get(f"/1.0/instances/{name}/logs/{filename}", raw=True)
        return data.decode("utf-8", errors="replace") if isinstance(data, bytes) else str(data)

    # -- storage / devices -------------------------------------------------

    async def list_storage_pools(self) -> list:
        pools = await self._meta("/1.0/storage-pools?recursion=1")
        return pools

    async def list_volumes(self, pool: str) -> list:
        return await self._meta(f"/1.0/storage-pools/{pool}/volumes?recursion=1")

    async def upload_iso(self, pool: str, name: str, file_path: str, timeout: int = 3600) -> dict:
        """Upload a local ISO file as a custom storage volume (content type 'iso').

        Equivalent to: lxc storage volume import <pool> <file> <name> --type=iso
        """
        await self.connect()
        assert self._session is not None
        size = os.path.getsize(file_path)
        headers = {
            "Content-Type": "application/octet-stream",
            "X-LXD-name": name,
            "X-LXD-type": "iso",
            "Content-Length": str(size),
        }

        async def file_sender():
            chunk = 1024 * 1024
            with open(file_path, "rb") as f:
                while True:
                    data = f.read(chunk)
                    if not data:
                        break
                    yield data

        url = f"{BASE}/1.0/storage-pools/{pool}/volumes/custom"
        async with self._session.post(
            url, data=file_sender(), headers=headers,
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as resp:
            body = await resp.json()
        if isinstance(body, dict) and body.get("type") == "error":
            raise LXDError(body.get("error", "iso upload failed"), body.get("error_code"))
        return await self.wait_operation(body, timeout=timeout)

    async def delete_volume(self, pool: str, name: str, vol_type: str = "custom") -> dict:
        return await self._request("DELETE", f"/1.0/storage-pools/{pool}/volumes/{vol_type}/{name}")

    async def list_profiles(self) -> list:
        return await self._meta("/1.0/profiles?recursion=1")

    async def get_profile(self, name: str) -> dict:
        return await self._meta(f"/1.0/profiles/{name}")

    async def put_profile(self, name: str, profile: dict) -> dict:
        """Create the profile if missing, else replace it (PUT)."""
        try:
            await self.get(f"/1.0/profiles/{name}")
            exists = True
        except LXDError:
            exists = False
        if exists:
            return await self._request("PUT", f"/1.0/profiles/{name}", data=profile)
        body = dict(profile)
        body["name"] = name
        return await self._request("POST", "/1.0/profiles", data=body)

    async def list_networks(self) -> list:
        return await self._meta("/1.0/networks?recursion=1")

    async def get_network(self, name: str) -> dict:
        """Return a network's config plus its runtime state (addresses, counters)."""
        net = await self._meta(f"/1.0/networks/{name}")
        try:
            net["state"] = await self._meta(f"/1.0/networks/{name}/state")
        except LXDError:
            net["state"] = None
        return net

    async def add_device(self, instance: str, dev_name: str, device: dict) -> dict:
        """Attach a device to an instance (PATCH merges into existing devices)."""
        resp = await self._request("PATCH", f"/1.0/instances/{instance}",
                                   data={"devices": {dev_name: device}})
        return await self.wait_operation(resp)

    async def remove_device(self, instance: str, dev_name: str) -> dict:
        """Detach a device. PATCH can't delete keys, so read-modify-write with PUT,
        sending only the writable fields (LXD ignores PUTs that include read-only
        fields like expanded_devices / status_code)."""
        inst = await self.get_instance(instance)
        devices = (inst.get("devices") or {}).copy()
        if dev_name not in devices:
            raise LXDError(f"device '{dev_name}' not on instance '{instance}'")
        devices.pop(dev_name)
        body = {
            "architecture": inst.get("architecture"),
            "config": inst.get("config", {}),
            "devices": devices,
            "profiles": inst.get("profiles", []),
            "description": inst.get("description", ""),
            "ephemeral": bool(inst.get("ephemeral", False)),
        }
        resp = await self._request("PUT", f"/1.0/instances/{instance}", data=body)
        return await self.wait_operation(resp)
