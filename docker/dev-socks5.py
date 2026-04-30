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
import traceback
from urllib.parse import unquote, urlparse


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


def recv_reply(sock: socket.socket) -> None:
    version, status, _, atyp = recv_exact(sock, 4)
    if version != 5 or status != 0:
        raise ConnectionError(f"upstream SOCKS5 connect failed: status={status}")
    if atyp == 1:
        recv_exact(sock, 4)
    elif atyp == 3:
        recv_exact(sock, recv_exact(sock, 1)[0])
    elif atyp == 4:
        recv_exact(sock, 16)
    else:
        raise ConnectionError(f"unsupported upstream reply atyp={atyp}")
    recv_exact(sock, 2)


def send_connect_request(sock: socket.socket, host: str, port: int) -> None:
    try:
        packed = socket.inet_aton(host)
        sock.sendall(b"\x05\x01\x00\x01" + packed + struct.pack("!H", port))
        return
    except OSError:
        pass

    try:
        packed = socket.inet_pton(socket.AF_INET6, host)
        sock.sendall(b"\x05\x01\x00\x04" + packed + struct.pack("!H", port))
        return
    except OSError:
        pass

    host_bytes = host.encode("utf-8")
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(host_bytes)]) + host_bytes + struct.pack("!H", port))


def connect_via_upstream(host: str, port: int, upstream: str) -> socket.socket:
    upstream = upstream.strip()
    if "://" not in upstream:
        upstream = f"socks5://{upstream}"

    parsed = urlparse(upstream)
    if parsed.scheme not in ("socks5", "socks5h"):
        raise ValueError(f"unsupported upstream scheme: {parsed.scheme}")

    upstream_host = parsed.hostname or ""
    upstream_port = parsed.port or 1080
    username = unquote(parsed.username or "")
    password = unquote(parsed.password or "")

    sock = socket.create_connection((upstream_host, upstream_port), timeout=15)
    if username:
        sock.sendall(b"\x05\x01\x02")
    else:
        sock.sendall(b"\x05\x01\x00")

    version, method = recv_exact(sock, 2)
    if version != 5 or method == 0xFF:
        raise ConnectionError("upstream SOCKS5 auth negotiation failed")

    if method == 0x02:
        user_bytes = username.encode("utf-8")
        pass_bytes = password.encode("utf-8")
        sock.sendall(b"\x01" + bytes([len(user_bytes)]) + user_bytes + bytes([len(pass_bytes)]) + pass_bytes)
        auth_version, auth_status = recv_exact(sock, 2)
        if auth_version != 1 or auth_status != 0:
            raise ConnectionError("upstream SOCKS5 auth rejected")
    elif method != 0x00:
        raise ConnectionError(f"unsupported upstream SOCKS5 auth method: {method}")

    send_connect_request(sock, host, port)
    recv_reply(sock)
    return sock


def handle_client(client: socket.socket, upstream_proxy: str = "") -> None:
    try:
        version, methods_len = recv_exact(client, 2)
        methods = recv_exact(client, methods_len)
        if version != 5 or 0 not in methods:
            client.sendall(b"\x05\xff")
            return
        client.sendall(b"\x05\x00")

        host, port = read_target(client)
        print(f"CONNECT {host}:{port}", flush=True)
        if upstream_proxy:
            upstream = connect_via_upstream(host, port, upstream_proxy)
        else:
            upstream = socket.create_connection((host, port), timeout=15)
        bind_host, bind_port = upstream.getsockname()[:2]
        try:
            reply = b"\x05\x00\x00\x01" + socket.inet_aton(bind_host) + struct.pack("!H", bind_port)
        except OSError:
            # Test helper only: a zero bind address keeps the CONNECT success
            # reply valid even when the host stack picked an IPv6 local socket.
            reply = b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"

        client.sendall(reply)
        pump(client, upstream)
    except Exception:
        traceback.print_exc()
        try:
            client.sendall(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
        except OSError:
            pass
    finally:
        try:
            client.close()
        except OSError:
            pass


def serve(host: str, port: int, upstream_proxy: str = "") -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(128)
    print(f"listening on socks5://{host}:{port}", flush=True)
    if upstream_proxy:
        print(f"upstream proxy: {upstream_proxy}", flush=True)
    try:
        while True:
            client, _ = server.accept()
            threading.Thread(target=handle_client, args=(client, upstream_proxy), daemon=True).start()
    finally:
        server.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=17890)
    parser.add_argument("--upstream", default="")
    args = parser.parse_args()
    serve(args.host, args.port, args.upstream)


if __name__ == "__main__":
    main()
