#!/usr/bin/env python3
"""Proxy-bridge config entry point.

Turn an arbitrary PROXY_URI supported by sing-box into a local authenticated
mixed inbound that child containers can consume via standard HTTP/SOCKS URLs.
"""

from __future__ import annotations

import os
import sys

from .protocols import parse
from .singbox import render_proxy_bridge_json


def main() -> None:
    uri = os.environ.get("PROXY_URI", "").strip()
    if not uri:
        print("Error: PROXY_URI is required.", file=sys.stderr)
        sys.exit(1)

    username = os.environ.get("CAC_CHILD_PROXY_BRIDGE_USER", "").strip()
    password = os.environ.get("CAC_CHILD_PROXY_BRIDGE_PASSWORD", "").strip()
    if not username or not password:
        print("Error: bridge auth credentials are required.", file=sys.stderr)
        sys.exit(1)

    listen_address = os.environ.get("CAC_CHILD_PROXY_BRIDGE_LISTEN", "0.0.0.0").strip() or "0.0.0.0"
    listen_port = int(os.environ.get("CAC_CHILD_PROXY_BRIDGE_PORT", "17891"))

    proxy = parse(uri)
    print(
        render_proxy_bridge_json(
            proxy,
            listen_address=listen_address,
            listen_port=listen_port,
            username=username,
            password=password,
        )
    )


if __name__ == "__main__":
    main()
