"""aiohttp web server: REST API over the LXD socket + WebSocket terminal proxy.

Run with:  python -m aklxd.server [--host H] [--port P] [--socket PATH]
"""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path

import aiohttp
from aiohttp import web

from . import config
from .lxd import LXDClient, LXDError

WEB_DIR = Path(__file__).resolve().parents[2] / "web"


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def ok(data):
    return web.json_response({"ok": True, "data": data})


def fail(message, status=400):
    return web.json_response({"ok": False, "error": str(message)}, status=status)


def lxd(request) -> LXDClient:
    return request.app["lxd"]


async def read_json(request) -> dict:
    if not request.can_read_body:
        return {}
    try:
        return await request.json()
    except json.JSONDecodeError:
        return {}


def guard(handler):
    """Wrap an API handler to turn LXD/connection errors into JSON responses."""
    async def wrapped(request):
        try:
            return await handler(request)
        except LXDError as e:
            return fail(e, status=502)
        except (ConnectionError, FileNotFoundError, aiohttp.ClientError) as e:
            return fail(f"Cannot reach LXD socket ({lxd(request).socket_path}): {e}", status=503)
    wrapped.__name__ = handler.__name__
    return wrapped


# --------------------------------------------------------------------------
# Server / dashboard
# --------------------------------------------------------------------------

@guard
async def api_server(request):
    info = await lxd(request).server_info()
    return ok(info)


@guard
async def api_resources(request):
    return ok(await lxd(request).resources())


# --------------------------------------------------------------------------
# Instances
# --------------------------------------------------------------------------

@guard
async def api_instances(request):
    return ok(await lxd(request).list_instances())


@guard
async def api_instance(request):
    name = request.match_info["name"]
    client = lxd(request)
    info = await client.get_instance(name)
    try:
        info["state"] = await client.instance_state(name)
    except LXDError:
        info["state"] = None
    return ok(info)


@guard
async def api_instance_create(request):
    payload = await read_json(request)
    if not payload.get("name"):
        return fail("'name' is required")
    return ok(await lxd(request).create_instance(payload))


@guard
async def api_instance_update(request):
    name = request.match_info["name"]
    payload = await read_json(request)
    return ok(await lxd(request).update_instance(name, payload))


@guard
async def api_instance_delete(request):
    name = request.match_info["name"]
    return ok(await lxd(request).delete_instance(name))


@guard
async def api_instance_state(request):
    name = request.match_info["name"]
    payload = await read_json(request)
    action = payload.get("action")
    if action not in ("start", "stop", "restart", "freeze", "unfreeze"):
        return fail("action must be one of start/stop/restart/freeze/unfreeze")
    return ok(await lxd(request).set_instance_state(
        name, action, force=bool(payload.get("force", False)),
        timeout=int(payload.get("timeout", 60)),
    ))


@guard
async def api_instance_exec(request):
    name = request.match_info["name"]
    payload = await read_json(request)
    command = payload.get("command")
    if not command:
        return fail("'command' is required")
    return ok(await lxd(request).exec_command(
        name, command,
        environment=payload.get("environment"),
        cwd=payload.get("cwd"),
        user=payload.get("user"),
    ))


# --------------------------------------------------------------------------
# Images
# --------------------------------------------------------------------------

@guard
async def api_images(request):
    return ok(await lxd(request).list_images())


@guard
async def api_image(request):
    return ok(await lxd(request).get_image(request.match_info["fingerprint"]))


@guard
async def api_image_update(request):
    fp = request.match_info["fingerprint"]
    return ok(await lxd(request).update_image(fp, await read_json(request)))


@guard
async def api_image_delete(request):
    return ok(await lxd(request).delete_image(request.match_info["fingerprint"]))


@guard
async def api_image_import(request):
    p = await read_json(request)
    if not p.get("server") or not p.get("alias"):
        return fail("'server' and 'alias' are required")
    return ok(await lxd(request).import_image(
        server=p["server"], alias=p["alias"],
        protocol=p.get("protocol", "simplestreams"),
        alias_local=p.get("alias_local"),
        image_type=p.get("image_type"),
    ))


@guard
async def api_image_alias(request):
    p = await read_json(request)
    if not p.get("fingerprint") or not p.get("name"):
        return fail("'fingerprint' and 'name' are required")
    return ok(await lxd(request).add_image_alias(
        p["fingerprint"], p["name"], p.get("description", "")))


@guard
async def api_image_alias_delete(request):
    return ok(await lxd(request).delete_image_alias(request.match_info["name"]))


# --------------------------------------------------------------------------
# Storage / devices (ISO upload + attach)
# --------------------------------------------------------------------------

@guard
async def api_storage(request):
    return ok(await lxd(request).list_storage_pools())


@guard
async def api_volumes(request):
    return ok(await lxd(request).list_volumes(request.match_info["pool"]))


@guard
async def api_iso_upload(request):
    """Upload a server-local ISO file into a pool as a custom 'iso' volume.

    Body: {"name": "<volume>", "path": "/abs/path/to.iso"}
    The path is read from the machine running this server.
    """
    pool = request.match_info["pool"]
    p = await read_json(request)
    name, path = p.get("name"), p.get("path")
    if not name or not path:
        return fail("'name' and 'path' are required")
    import os
    if not os.path.isfile(path):
        return fail(f"file not found: {path}", status=404)
    return ok(await lxd(request).upload_iso(pool, name, path))


@guard
async def api_volume_delete(request):
    return ok(await lxd(request).delete_volume(
        request.match_info["pool"], request.match_info["name"]))


@guard
async def api_profiles(request):
    return ok(await lxd(request).list_profiles())


@guard
async def api_profile(request):
    return ok(await lxd(request).get_profile(request.match_info["name"]))


@guard
async def api_profile_put(request):
    name = request.match_info["name"]
    return ok(await lxd(request).put_profile(name, await read_json(request)))


@guard
async def api_networks(request):
    return ok(await lxd(request).list_networks())


@guard
async def api_network(request):
    return ok(await lxd(request).get_network(request.match_info["name"]))


@guard
async def api_device_add(request):
    name = request.match_info["name"]
    p = await read_json(request)
    if not p.get("name") or not isinstance(p.get("device"), dict):
        return fail("'name' and 'device' (object) are required")
    return ok(await lxd(request).add_device(name, p["name"], p["device"]))


@guard
async def api_device_remove(request):
    return ok(await lxd(request).remove_device(
        request.match_info["name"], request.match_info["device"]))


# --------------------------------------------------------------------------
# WebSocket terminal proxy (exec + console)
# --------------------------------------------------------------------------

async def _proxy(client_ws: web.WebSocketResponse, data_ws, control_ws):
    """Bridge a browser xterm.js websocket to an LXD operation websocket.

    Protocol from the browser:
      * BINARY / TEXT frame  -> terminal keystrokes, forwarded to LXD.
      * TEXT frame {"type":"resize","width":W,"height":H} -> window resize.
    """
    import asyncio

    async def browser_to_lxd():
        async for msg in client_ws:
            if msg.type == aiohttp.WSMsgType.BINARY:
                await data_ws.send_bytes(msg.data)
            elif msg.type == aiohttp.WSMsgType.TEXT:
                txt = msg.data
                if txt.startswith("{"):
                    try:
                        obj = json.loads(txt)
                    except ValueError:
                        obj = None
                    if obj and obj.get("type") == "resize" and control_ws is not None:
                        await control_ws.send_json({
                            "command": "window-resize",
                            "args": {"width": str(obj["width"]), "height": str(obj["height"])},
                        })
                        continue
                await data_ws.send_str(txt)
            else:
                break
        if not data_ws.closed:
            await data_ws.close()

    async def lxd_to_browser():
        async for msg in data_ws:
            if client_ws.closed:
                break
            if msg.type == aiohttp.WSMsgType.BINARY:
                await client_ws.send_bytes(msg.data)
            elif msg.type == aiohttp.WSMsgType.TEXT:
                await client_ws.send_str(msg.data)
            else:
                break
        if not client_ws.closed:
            await client_ws.close()

    await asyncio.gather(browser_to_lxd(), lxd_to_browser(), return_exceptions=True)
    for ws in (data_ws, control_ws):
        if ws is not None and not ws.closed:
            await ws.close()


async def _attach_fds(client, op, fds):
    """Connect the operation's control socket, then its data socket.

    Order matters: connecting the data socket first makes LXD start the console
    and the operation leaves the "Running" state, after which the control socket
    can no longer attach ("Only running operations can be connected"). So connect
    control first. The control socket only carries window-resize, so a failure
    there must never abort the session — we just lose resize.
    """
    control_ws = None
    if fds.get("control"):
        try:
            control_ws = await client.operation_websocket(op, fds["control"])
        except (aiohttp.ClientError, ConnectionError):
            control_ws = None  # resize unavailable, but the console still works
    data_ws = await client.operation_websocket(op, fds["0"])
    return data_ws, control_ws


async def ws_exec(request):
    name = request.match_info["name"]
    cmd = request.query.get("cmd", "/bin/bash")
    try:
        command = shlex.split(cmd) if cmd else ["/bin/bash"]
    except ValueError:
        command = ["/bin/bash"]

    client_ws = web.WebSocketResponse()
    await client_ws.prepare(request)
    try:
        op, fds = await lxd(request).exec_interactive(name, command)
    except (LXDError, aiohttp.ClientError, ConnectionError) as e:
        await client_ws.send_str(f"\r\n[ak-lxd-helper] exec failed: {e}\r\n")
        await client_ws.close()
        return client_ws

    data_ws, control_ws = await _attach_fds(lxd(request), op, fds)
    await _proxy(client_ws, data_ws, control_ws)
    return client_ws


async def ws_console(request):
    name = request.match_info["name"]
    client_ws = web.WebSocketResponse()
    await client_ws.prepare(request)
    try:
        op, fds = await lxd(request).console(name)
    except (LXDError, aiohttp.ClientError, ConnectionError) as e:
        await client_ws.send_str(f"\r\n[ak-lxd-helper] console failed: {e}\r\n")
        await client_ws.close()
        return client_ws

    data_ws, control_ws = await _attach_fds(lxd(request), op, fds)
    await client_ws.send_str(
        "\r\n[ak-lxd-helper] console attached. If the screen is blank: press "
        "Enter for a login/shell prompt, or Redraw for a full-screen app "
        "(installer).\r\n")
    await _proxy(client_ws, data_ws, control_ws)
    return client_ws


# --------------------------------------------------------------------------
# App wiring
# --------------------------------------------------------------------------

async def index(request):
    return web.FileResponse(WEB_DIR / "index.html")


async def on_cleanup(app):
    await app["lxd"].close()


def make_app(socket_path: str) -> web.Application:
    app = web.Application()
    app["lxd"] = LXDClient(socket_path)
    app.on_cleanup.append(on_cleanup)

    app.add_routes([
        web.get("/", index),
        web.get("/api/server", api_server),
        web.get("/api/resources", api_resources),

        web.get("/api/instances", api_instances),
        web.post("/api/instances", api_instance_create),
        web.get("/api/instances/{name}", api_instance),
        web.patch("/api/instances/{name}", api_instance_update),
        web.delete("/api/instances/{name}", api_instance_delete),
        web.post("/api/instances/{name}/state", api_instance_state),
        web.post("/api/instances/{name}/exec", api_instance_exec),

        web.get("/api/images", api_images),
        web.post("/api/images/import", api_image_import),
        web.post("/api/images/aliases", api_image_alias),
        web.delete("/api/images/aliases/{name}", api_image_alias_delete),
        web.get("/api/images/{fingerprint}", api_image),
        web.patch("/api/images/{fingerprint}", api_image_update),
        web.delete("/api/images/{fingerprint}", api_image_delete),

        web.get("/api/storage", api_storage),
        web.get("/api/storage/{pool}/volumes", api_volumes),
        web.post("/api/storage/{pool}/isos", api_iso_upload),
        web.delete("/api/storage/{pool}/volumes/{name}", api_volume_delete),

        web.post("/api/instances/{name}/devices", api_device_add),
        web.delete("/api/instances/{name}/devices/{device}", api_device_remove),

        web.get("/api/networks", api_networks),
        web.get("/api/networks/{name}", api_network),

        web.get("/api/profiles", api_profiles),
        web.get("/api/profiles/{name}", api_profile),
        web.put("/api/profiles/{name}", api_profile_put),

        web.get("/ws/exec/{name}", ws_exec),
        web.get("/ws/console/{name}", ws_console),

        web.static("/static", WEB_DIR),
    ])
    return app


def main():
    parser = argparse.ArgumentParser(description="ak-lxd-helper web dashboard")
    parser.add_argument("--host", default=config.HOST)
    parser.add_argument("--port", type=int, default=config.PORT)
    parser.add_argument("--socket", default=config.resolve_socket(),
                        help="path to the LXD Unix socket")
    args = parser.parse_args()

    print(f"ak-lxd-helper -> http://{args.host}:{args.port}")
    print(f"LXD socket: {args.socket}")
    if not Path(args.socket).exists():
        print("  WARNING: socket not found. On the mac, forward it over SSH first")
        print("  (see README 'Local development'). The UI will load but API calls will fail.")
    web.run_app(make_app(args.socket), host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()
