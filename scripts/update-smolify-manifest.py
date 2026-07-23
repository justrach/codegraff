#!/usr/bin/env python3
"""Refresh the deterministic, locally bundled Smolify MCP tool manifest."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.request


ENDPOINT = "https://app.smol.ly/mcp"
PROTOCOL = "2025-11-25"
ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "src" / "smolify-tools.json"


def post(payload: dict[str, object], session_id: str | None) -> tuple[dict[str, object] | None, str | None]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Mcp-Protocol-Version": PROTOCOL,
        "User-Agent": "codegraff-smolify-manifest/1",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(payload, separators=(",", ":")).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read().decode()
        session_id = response.headers.get("Mcp-Session-Id") or session_id
    if not body:
        return None, session_id
    if body.lstrip().startswith("data:"):
        expected_id = payload.get("id")
        for line in body.splitlines():
            if not line.startswith("data:"):
                continue
            candidate = json.loads(line.removeprefix("data:").strip())
            if candidate.get("id") == expected_id:
                return candidate, session_id
        raise RuntimeError("Smolify SSE response omitted the matching JSON-RPC id")
    return json.loads(body), session_id


def fetch_manifest() -> bytes:
    initialized, session_id = post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL,
                "capabilities": {},
                "clientInfo": {"name": "codegraff-smolify-manifest", "version": "1"},
            },
        },
        None,
    )
    if not initialized:
        raise RuntimeError("Smolify initialize returned no response")
    negotiated = initialized.get("result", {}).get("protocolVersion")
    post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, session_id)
    listed, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, session_id)
    if not listed:
        raise RuntimeError("Smolify tools/list returned no response")
    tools = listed.get("result", {}).get("tools")
    if not isinstance(tools, list) or not tools:
        raise RuntimeError("Smolify tools/list returned an empty or invalid manifest")
    projected = []
    for tool in tools:
        projected.append(
            {
                key: tool[key]
                for key in ("name", "title", "description", "inputSchema")
                if key in tool
            }
        )
    normalized = {"protocolVersion": negotiated, "tools": projected}
    return (json.dumps(normalized, separators=(",", ":"), sort_keys=True) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when the live manifest differs")
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    current = args.output.read_bytes() if args.output.exists() else b""
    fetched = fetch_manifest()
    if args.check:
        if current != fetched:
            print("bundled Smolify manifest differs from the live endpoint", file=sys.stderr)
            return 1
        print("bundled Smolify manifest is current")
        return 0
    args.output.write_bytes(fetched)
    print(f"wrote {args.output} ({len(fetched)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
