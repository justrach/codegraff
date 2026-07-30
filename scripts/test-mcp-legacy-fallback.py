#!/usr/bin/env python3
"""Offline end-to-end proof that graff's HTTP MCP client still falls back to
the pre-2026-07-28 handshake byte-for-byte. The fixture answers the modern
probe (an unadorned `tools/list`) with a 400 shaped like the real TS SDK's
pre-initialize rejection, then requires the legacy `initialize` ->
`notifications/initialized` -> `tools/list` sequence — each request must be
indistinguishable from what graff sent before this migration: no `_meta`,
no `Mcp-Method`/`Mcp-Name` header, and the negotiated `Mcp-Session-Id`
echoed once the fixture has minted one."""

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


LEGACY_PROTOCOL = "2025-11-25"
NEGOTIATED_PROTOCOL = "2025-06-18"
SESSION_ID = "graff-mcp-fixture-session"

# The real TS SDK's shape for "you didn't call initialize first" — id is
# null because the server never learned graff's request id.
MODERN_PROBE_REJECTION = json.dumps(
    {
        "jsonrpc": "2.0",
        "error": {"code": -32000, "message": "Bad Request: Server not initialized"},
        "id": None,
    },
    separators=(",", ":"),
).encode()


class McpFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests: list[dict[str, Any]] = []
    failure: BaseException | None = None
    lock = threading.Lock()

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def _respond(
        self,
        status: int,
        body: bytes = b"",
        content_type: str | None = None,
        session_id: str | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        if session_id is not None:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()
        if body:
            self.wfile.write(body)

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

            with self.lock:
                ordinal = len(self.requests) + 1
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

            # Every legacy-shaped request (everything after the modern probe)
            # must carry neither Mcp-Method nor Mcp-Name — that pair only
            # exists in the stateless 2026-07-28 wire format.
            if ordinal > 1:
                assert self.headers.get("Mcp-Method") is None
                assert self.headers.get("Mcp-Name") is None
                assert "_meta" not in raw.decode("utf-8")

            if ordinal == 1:
                # The modern probe: an unadorned tools/list, no handshake.
                assert message["method"] == "tools/list"
                assert message["id"] == 1
                assert "_meta" in message["params"]
                assert self.headers.get("Mcp-Protocol-Version") == "2026-07-28"
                assert self.headers.get("Mcp-Method") == "tools/list"
                assert self.headers.get("Mcp-Session-Id") is None
                self._respond(400, MODERN_PROBE_REJECTION, "application/json")
                return

            if ordinal == 2:
                assert message["method"] == "initialize"
                assert message["id"] == 2
                assert message["params"]["protocolVersion"] == LEGACY_PROTOCOL
                assert self.headers.get("Mcp-Protocol-Version") == LEGACY_PROTOCOL
                # No session minted yet: nothing to echo on the request that
                # establishes one.
                assert self.headers.get("Mcp-Session-Id") is None
                body = json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "result": {
                            "protocolVersion": NEGOTIATED_PROTOCOL,
                            "capabilities": {"tools": {}},
                            "serverInfo": {"name": "fixture", "version": "1"},
                        },
                    },
                    separators=(",", ":"),
                ).encode()
                self._respond(200, body, "application/json", SESSION_ID)
                return

            assert self.headers.get("Mcp-Protocol-Version") == NEGOTIATED_PROTOCOL
            assert self.headers.get("Mcp-Session-Id") == SESSION_ID
            if ordinal == 3:
                assert message == {
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": {},
                }
                self._respond(202)
                return

            assert ordinal == 4
            assert message["method"] == "tools/list"
            assert message["id"] == 3
            body = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "result": {
                        "tools": [
                            {
                                "name": "fixture_search",
                                "description": "Search public fixture docs.",
                                "inputSchema": {"type": "object", "properties": {}},
                            }
                        ]
                    },
                },
                separators=(",", ":"),
            ).encode()
            self._respond(200, body, "application/json")
        except BaseException as exc:
            self.failure = exc
            self._respond(500)


def run(graff: Path) -> None:
    McpFixture.requests = []
    McpFixture.failure = None
    server = ThreadingHTTPServer(("127.0.0.1", 0), McpFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-mcp-legacy-") as temp:
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
            assert len(McpFixture.requests) == 4, McpFixture.requests
            assert (
                f"[mcp:fixture] connected (mcp {NEGOTIATED_PROTOCOL}) — 1 tool(s)"
                in completed.stderr
            ), completed.stderr
            # Byte-identity guard across the three legacy requests: no _meta
            # anywhere, and Mcp-Session-Id echoed once minted (requests 3-4;
            # request 2 is the one that establishes it, so it has none yet).
            for i, req in enumerate(McpFixture.requests[1:], start=2):
                assert "_meta" not in req["raw"], (i, req)
                if i >= 3:
                    assert req["session"] == SESSION_ID, (i, req)
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
    print("Legacy fallback MCP E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
