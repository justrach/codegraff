#!/usr/bin/env python3
"""Offline end-to-end smoke for Graff's modern (2026-07-28) Streamable HTTP
MCP probe: a server that answers the first, handshake-free `tools/list`
request costs exactly one POST — no `initialize`, no
`notifications/initialized`. See test-mcp-legacy-fallback.py for the
backward-compat proof (a server that rejects the modern probe)."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import ScriptedModel


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

            assert ordinal == 1, f"expected exactly one request, saw a {ordinal}th"
            assert message["method"] == "tools/list"
            assert message["id"] == 1
            meta = message["params"]["_meta"]
            for key in RESERVED_META_KEYS:
                assert key in meta, f"missing reserved _meta key {key}"
            assert meta["io.modelcontextprotocol/protocolVersion"] == MODERN_PROTOCOL
            assert self.headers.get("Mcp-Protocol-Version") == MODERN_PROTOCOL
            assert self.headers.get("Mcp-Method") == "tools/list"
            assert self.headers.get("Mcp-Session-Id") is None

            body = json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
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
                    "GRAFF_REPL_DEBUG": "1",
                    "HOME": str(workspace),
                    "USERPROFILE": str(workspace),
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
            assert len(McpFixture.requests) == 1, McpFixture.requests
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


def run_task_deadline(graff: Path) -> None:
    """A delayed tool failure must arrive intact, after the old 15-second bound."""
    class TaskFixture(BaseHTTPRequestHandler):
        calls = 0

        def log_message(self, _format: str, *_args: object) -> None:
            pass

        def do_POST(self) -> None:  # noqa: N802
            message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if message["method"] == "tools/list":
                result = {"tools": [{"name": "run_task", "description": "Run the fixture task.",
                    "inputSchema": {"type": "object", "properties": {
                        "prompt": {"type": "string"}, "timeout_seconds": {"type": "integer"}},
                        "required": ["prompt"]}}]}
            elif message["method"] == "tools/call":
                TaskFixture.calls += 1
                time.sleep(16)
                result = {"isError": True, "content": [{"type": "text", "text":
                    "MCP_PARTIAL_WORK\n[Task timed out; partial work may remain.]"}],
                    "structuredContent": {"status": "timed_out", "text": "MCP_PARTIAL_WORK"}}
            else:
                result = {}
            if "id" not in message:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except BrokenPipeError:
                pass  # The unfixed client closes before the delayed result.

    server = ThreadingHTTPServer(("127.0.0.1", 0), TaskFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    model = ScriptedModel([
        {"tool": "load_tool_schemas", "arguments": {"server": "fixture"}},
        {"tool": "mcp__fixture__run_task", "arguments": {
            "prompt": "Return the fixture result.", "timeout_seconds": 16}},
        {"text": "MCP_DEADLINE_DONE"},
    ])
    thread.start()
    try:
        model.start(1234)
        with tempfile.TemporaryDirectory(prefix="graff-mcp-deadline-") as temp:
            workspace = Path(temp)
            (workspace / ".mcp.json").write_text(json.dumps({"mcpServers": {
                "fixture": {"url": f"http://127.0.0.1:{server.server_port}/mcp"}}}))
            env = {"PATH": os.environ.get("PATH", ""), "HOME": temp, "USERPROFILE": temp,
                   "LMSTUDIO_API_KEY": "local-fixture", "GRAFF_FLEET": "off",
                   "GRAFF_NO_PLUGINS": "1", "GRAFF_NO_TELEMETRY": "1",
                   "GRAFF_NO_SMOLIFY": "1", "GRAFF_BEHAVIOR_TRACE": "0"}
            completed = subprocess.run([str(graff), "--json", "--yolo", "--no-resume",
                "--model", "lmstudio", "--max-model-calls", "5"], cwd=workspace,
                env=env, input=json.dumps({"type": "user", "text":
                    "Use the fixture run_task once and report its result. No file access is needed."}) + "\n",
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
            assert completed.returncode == 0, completed.stderr
            assert TaskFixture.calls == 1, TaskFixture.calls
            tool_replies = [message.get("content", "") for request in model.requests
                            for message in request.get("messages", []) if message.get("role") == "tool"]
            assert any("MCP_PARTIAL_WORK" in text for text in tool_replies), tool_replies
            assert not any("McpRequestTimedOut" in text for text in tool_replies), tool_replies
            assert "MCP_DEADLINE_DONE" in completed.stdout, completed.stdout
    finally:
        model.stop()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    parser.add_argument("--only-task-deadline", action="store_true")
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    if not args.only_task_deadline:
        run(graff)
    run_task_deadline(graff)
    print("Streamable HTTP MCP E2E passed (including delayed task failure with partial output)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
