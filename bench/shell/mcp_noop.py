#!/usr/bin/env python3
"""Newline-delimited stdio MCP server with no tools. Handshake only."""
from __future__ import annotations

import json
import sys


def send(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main() -> None:
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "noop", "version": "1"},
                },
            })
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": []}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})


if __name__ == "__main__":
    main()
