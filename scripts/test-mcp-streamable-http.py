#!/usr/bin/env python3
"""Offline end-to-end smoke for Graff's Streamable HTTP MCP first-launch
handshake. Deferred startup overlaps `server/discover` + `tools/list` + at
most one `initialize` (mcp_lifecycle.zig). A modern `tools/list` result is
enough to mark the era; a second initialize is a bug, not a fixture gap.
See test-mcp-legacy-fallback.py for the backward-compat proof.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from typing import Any


MODERN_PROTOCOL = "2026-07-28"
RESERVED_META_KEYS = (
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/clientCapabilities",
)


class McpFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests: list[dict[str, Any]] = []
    failure: BaseException | None = None
    lock = threading.Lock()
    seen: dict[str, int] = {}

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _respond(self, status: int, body: bytes = b"", content_type: str | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":")).encode()
        self._respond(200, raw, "application/json")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            message = json.loads(raw)
            assert self.path == "/mcp"
            assert self.headers.get_content_type() == "application/json"
            accept = self.headers.get("Accept", "")
            assert "application/json" in accept
            assert "text/event-stream" in accept
            assert self.headers.get("Authorization") is None

            method = message["method"]
            with self.lock:
                self.seen[method] = self.seen.get(method, 0) + 1
                if method == "initialize" and self.seen[method] > 1:
                    raise AssertionError(
                        f"duplicate initialize (id {message.get('id')}): first-launch may overlap one handshake, not two"
                    )
                self.requests.append(
                    {
                        "message": message,
                        "protocol": self.headers.get("Mcp-Protocol-Version"),
                        "method_header": self.headers.get("Mcp-Method"),
                        "name_header": self.headers.get("Mcp-Name"),
                        "session": self.headers.get("Mcp-Session-Id"),
                        "raw": raw.decode("utf-8"),
                    }
                )

            req_id = message["id"]
            if method == "tools/list":
                meta = message["params"]["_meta"]
                for key in RESERVED_META_KEYS:
                    assert key in meta, f"missing reserved _meta key {key}"
                assert meta["io.modelcontextprotocol/protocolVersion"] == MODERN_PROTOCOL
                assert self.headers.get("Mcp-Protocol-Version") == MODERN_PROTOCOL
                assert self.headers.get("Mcp-Method") == "tools/list"
                assert self.headers.get("Mcp-Session-Id") is None
                self._json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "tools": [
                                {
                                    "name": "fixture_search",
                                    "description": "Search public fixture docs.",
                                    "inputSchema": {
                                        "type": "object",
                                        "properties": {
                                            "query": {
                                                "oneOf": [
                                                    {"type": "string"},
                                                    {"type": "null"},
                                                ]
                                            }
                                        },
                                    },
                                }
                            ]
                        },
                    }
                )
                return
            if method == "server/discover":
                self._json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"supportedVersions": [MODERN_PROTOCOL, "2025-11-25"]},
                    }
                )
                return
            if method == "initialize":
                self._json(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "protocolVersion": message["params"].get("protocolVersion", "2025-11-25"),
                            "capabilities": {},
                            "serverInfo": {"name": "fixture", "version": "0"},
                        },
                    }
                )
                return
            if method == "notifications/initialized":
                self._respond(202)
                return
            raise AssertionError(f"unexpected MCP method {method}")
        except BaseException as exc:
            self.failure = exc
            self._respond(500)


def run(graff: Path) -> None:
    McpFixture.requests = []
    McpFixture.failure = None
    McpFixture.seen = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), McpFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-mcp-http-") as temp:
            workspace = Path(temp)
            (workspace / ".mcp.json").write_text(
                json.dumps(
                    {
                        "mcpServers": {
                            "fixture": {
                                "url": f"http://127.0.0.1:{server.server_port}/mcp"
                            }
                        }
                    },
                    separators=(",", ":"),
                ),
                encoding="utf-8",
            )
            settings = workspace / ".harness" / "settings.json"
            settings.parent.mkdir(mode=0o700)
            settings.write_text(
                '{"skills":{"codedbpro":false,"muonry":false}}\n',
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "ANTHROPIC_API_KEY": "fixture-not-used",
                    "GRAFF_BEHAVIOR_TRACE": "0",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_SMOLIFY": "1",
                    "GRAFF_NO_TELEMETRY": "1",
                }
            )
            completed = subprocess.run(
                [str(graff), "--json", "--yolo", "--model", "claude"],
                cwd=workspace,
                env=env,
                input="",
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=20,
                check=False,
            )
            if completed.returncode != 0:
                raise AssertionError(
                    f"graff exited {completed.returncode}\n"
                    f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
                )
            if McpFixture.failure is not None:
                raise AssertionError("MCP fixture rejected a request") from McpFixture.failure
            methods = [r["message"]["method"] for r in McpFixture.requests]
            assert "server/discover" in methods, methods
            assert "tools/list" in methods, methods
            assert methods.count("initialize") <= 1, methods
            assert (
                f"[mcp:fixture] connected (mcp {MODERN_PROTOCOL}) — 1 tool(s)"
                in completed.stderr
            ), completed.stderr
            serialized = json.dumps(McpFixture.requests, separators=(",", ":"))
            assert str(workspace) not in serialized
            assert "fixture-not-used" not in serialized
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    run(graff)
    print("Streamable HTTP MCP E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
