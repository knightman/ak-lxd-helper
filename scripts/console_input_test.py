#!/usr/bin/env python3
"""Dependency-free LXD console input test over a Unix socket.

Connects control+data websockets to a VM console, sends a keystroke, and
reports how many output bytes arrive before/after — to determine whether
console *input* actually reaches the guest. Stdlib only (runs on the LXD host).

Usage: console_input_test.py <socket-path> <instance>
"""
import base64
import http.client
import json
import os
import socket
import sys
import time


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("lxd")
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self._path)


def ws_upgrade(path, url):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {url} HTTP/1.1\r\n"
        "Host: lxd\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(1)
        if not chunk:
            break
        buf += chunk
    status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
    return s, status, buf


def ws_send(sock, data, opcode=0x2):
    fin_op = 0x80 | opcode
    n = len(data)
    header = bytes([fin_op])
    mask_bit = 0x80
    if n < 126:
        header += bytes([mask_bit | n])
    elif n < 65536:
        header += bytes([mask_bit | 126]) + n.to_bytes(2, "big")
    else:
        header += bytes([mask_bit | 127]) + n.to_bytes(8, "big")
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(header + mask + masked)


def ws_recv_all(sock, seconds):
    """Read websocket frames for `seconds`; return total payload bytes."""
    sock.settimeout(0.5)
    total = bytearray()
    end = time.time() + seconds
    buf = b""
    while time.time() < end:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            continue
        # parse as many frames as available
        while len(buf) >= 2:
            b0, b1 = buf[0], buf[1]
            ln = b1 & 0x7F
            idx = 2
            if ln == 126:
                if len(buf) < 4:
                    break
                ln = int.from_bytes(buf[2:4], "big"); idx = 4
            elif ln == 127:
                if len(buf) < 10:
                    break
                ln = int.from_bytes(buf[2:10], "big"); idx = 10
            if len(buf) < idx + ln:
                break
            payload = buf[idx:idx + ln]
            buf = buf[idx + ln:]
            opcode = b0 & 0x0F
            if opcode in (0x1, 0x2):
                total += payload
    return bytes(total)


def main():
    path, inst = sys.argv[1], sys.argv[2]
    conn = UnixHTTP(path)
    conn.request("POST", f"/1.0/instances/{inst}/console",
                 body=json.dumps({"width": 120, "height": 40, "type": "console"}),
                 headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    body = json.loads(resp.read())
    op = body["operation"]
    fds = body["metadata"]["metadata"]["fds"]
    print("op:", op, "fds:", list(fds))

    cs, cstat, _ = ws_upgrade(path, f"{op}/websocket?secret={fds['control']}")
    print("control upgrade:", cstat)
    ds, dstat, _ = ws_upgrade(path, f"{op}/websocket?secret={fds['0']}")
    print("data upgrade:", dstat)

    before = ws_recv_all(ds, 1.5)
    print("bytes before input:", len(before))
    ws_send(ds, b"\r")          # Enter
    time.sleep(0.3)
    ws_send(ds, b"\x1b[B")      # Down
    after = ws_recv_all(ds, 3.0)
    print("bytes after input:", len(after))
    print("RESULT:", "INPUT WORKS" if len(after) > 0 else "NO INPUT RESPONSE")
    for s in (cs, ds):
        try:
            s.close()
        except OSError:
            pass


if __name__ == "__main__":
    main()
