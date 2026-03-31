#!/usr/bin/env python3
"""Small local SOCKS5 proxy for Docker-mode fail-closed tests.

Supports:
- NO AUTHENTICATION REQUIRED
- CONNECT
- IPv4 and domain-name targets
"""

from __future__ import annotations

import argparse
import select
import socket
import struct
import threading


def recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)


def pump(a: socket.socket, b: socket.socket) -> None:
    sockets = [a, b]
    try:
        while True:
            readable, _, _ = select.select(sockets, [], [], 30)
            if not readable:
                continue
            for src in readable:
                dst = b if src is a else a
                data = src.recv(65536)
                if not data:
                    return
                dst.sendall(data)
    finally:
        for sock in sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


def read_target(client: socket.socket) -> tuple[str, int]:
    version, cmd, _, atyp = recv_exact(client, 4)
    if version != 5 or cmd != 1:
        raise ValueError("unsupported SOCKS5 request")

    if atyp == 1:
        host = socket.inet_ntoa(recv_exact(client, 4))
    elif atyp == 3:
        length = recv_exact(client, 1)[0]
        host = recv_exact(client, length).decode("utf-8", "replace")
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
    else:
        raise ValueError("unsupported address type")

    port = struct.unpack("!H", recv_exact(client, 2))[0]
    return host, port


def handle_client(client: socket.socket) -> None:
    try:
        version, methods_len = recv_exact(client, 2)
        methods = recv_exact(client, methods_len)
        if version != 5 or 0 not in methods:
            client.sendall(b"\x05\xff")
            return
        client.sendall(b"\x05\x00")

        host, port = read_target(client)
        upstream = socket.create_connection((host, port), timeout=15)
        bind_host, bind_port = upstream.getsockname()[:2]

        client.sendall(
            b"\x05\x00\x00\x01" + socket.inet_aton(bind_host) + struct.pack("!H", bind_port)
        )
        pump(client, upstream)
    except Exception:
        try:
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
        except OSError:
            pass
    finally:
        try:
            client.close()
        except OSError:
            pass


def serve(host: str, port: int) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(128)
    print(f"listening on socks5://{host}:{port}", flush=True)
    try:
        while True:
            client, _ = server.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
    finally:
        server.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=17890)
    args = parser.parse_args()
    serve(args.host, args.port)


if __name__ == "__main__":
    main()
