#!/usr/bin/env python3
"""Offline end-to-end proof of the #330 `--no-local-tools` embedder gate.

One scripted codex/Responses mock plus one Streamable HTTP MCP server stand in
for the embedder's shape: the harness runs on the trusted host, the sandbox is
reached only through MCP. Two scenarios run the same script.

gated (`--no-local-tools`)
    * the tools array the provider receives carries none of the gated local
    execution tools (including folded `monitor`), still carries webfetch/orchestration, and still carries the
    MCP server's tool;
  * a hallucinated `bash` call comes back as a tool error naming the flag, and
    the command never runs (the marker it would print appears nowhere);
  * a subagent inherits the gate - its own catalog is filtered too, and its
    hallucinated `bash` call is refused the same way;
  * the MCP tool still executes and its result reaches the model.

control (same script, no flag)
  * the identical `bash` call runs and its output comes back, so the diff
    between the two runs is the gate and nothing else.
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import threading
from typing import Any

from codex_ws_mock import CodexMock, RecordedRequest

GATED_TOOLS = (
    "bash",
    "bash_output",
    "bash_kill",
    "monitor",
    "read_file",
    "edit_file",
    "write_file",
    "codedb",
)
# The marker is split by an empty shell quote, so the whole string only ever
# exists because /bin/sh actually ran the command - it is not a substring of the
# command text the model sent, which is echoed back in requests and events.
ESCAPE_MARKER = "GATE_ESCAPED_a26362"
BASH_COMMAND = "printf %s GATE_ESCAPED''_a26362"
MCP_RESULT = "sandbox exec ok (via MCP)"
FINAL_TEXT = "done"

ROOT_BASH_CALL = "call_root_bash"
SUBAGENT_CALL = "call_root_subagent"
MCP_CALL = "call_root_mcp"
CHILD_BASH_CALL = "call_child_bash"


class SandboxMcp(BaseHTTPRequestHandler):
    """A stand-in for the embedder's sandbox-proxy MCP server."""

    protocol_version = "HTTP/1.1"
    calls: list[dict[str, Any]] = []
    lock = threading.Lock()

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        message = json.loads(self.rfile.read(length))
        method = message.get("method")
        if method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "exec",
                        "description": "Run a command inside the sandbox VM.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"command": {"type": "string"}},
                            "required": ["command"],
                        },
                    }
                ]
            }
        elif method == "tools/call":
            with self.lock:
                self.calls.append(message.get("params", {}))
            result = {"content": [{"type": "text", "text": MCP_RESULT}]}
        else:
            result = {}
        body = json.dumps(
            {"jsonrpc": "2.0", "id": message.get("id"), "result": result},
            separators=(",", ":"),
        ).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


def message_item(text: str, item_id: str) -> dict:
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def call_item(name: str, call_id: str, arguments: dict) -> dict:
    return {
        "type": "function_call",
        "id": f"fc_{call_id}",
        "call_id": call_id,
        "name": name,
        "arguments": json.dumps(arguments, separators=(",", ":")),
        "status": "completed",
    }


def response_events(item: dict, response_id: str) -> list[dict]:
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 900,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 100,
                    "total_tokens": 1000,
                },
            },
        },
    ]


def tool_names(request: RecordedRequest) -> list[str]:
    tools = request.body.get("tools")
    return [t.get("name") for t in tools] if isinstance(tools, list) else []


def catalog_names(request: RecordedRequest) -> list[str]:
    """Wire tools plus names carried in load_tool_schemas' deferred listing:
    ``Folded native: workflow, ...;`` and ``server (tool, ...)`` MCP groups."""
    names = list(tool_names(request))
    tools = request.body.get("tools")
    if isinstance(tools, list):
        for tool in tools:
            if isinstance(tool, dict) and tool.get("name") == "load_tool_schemas":
                description = tool.get("description", "")
                folded = re.search(r"Folded native:\s*([^;]+);", description)
                if folded:
                    for name in folded.group(1).split(","):
                        name = name.strip()
                        if re.fullmatch(r"[a-z0-9_]+", name):
                            names.append(name)
                for server, group in re.findall(r"([a-z0-9_]+) \(([^)]*)\)", description):
                    for name in group.split(","):
                        name = name.strip()
                        if name and re.fullmatch(r"[a-z0-9_]+", name):  # prose parens carry spaces
                            names.append(f"mcp__{server}__{name}")
    return names


def mcp_tool_name(names: list[str]) -> str:
    remote = [n for n in names if isinstance(n, str) and n.startswith("mcp__")]
    if len(remote) != 1:
        raise AssertionError(f"expected exactly one MCP tool, saw {remote!r}")
    return remote[0]


def script(request: RecordedRequest) -> list[dict]:
    """Drive root and child through the same fixed sequence of tool calls.

    Keyed on which call ids the request's own input already carries, so it does
    not depend on how root and child requests interleave in wall-clock order.
    """
    names = tool_names(request)
    seen = json.dumps(request.body.get("input"), separators=(",", ":"))
    tag = f"resp_{request.ordinal}"
    if "load_tool_schemas" not in names:  # a child: the root-only meta tool is absent
        if CHILD_BASH_CALL not in seen:
            return response_events(
                call_item("bash", CHILD_BASH_CALL, {"command": BASH_COMMAND}), tag
            )
        return response_events(message_item("child done", f"msg_{tag}"), tag)
    if ROOT_BASH_CALL not in seen:
        return response_events(
            call_item("bash", ROOT_BASH_CALL, {"command": BASH_COMMAND}), tag
        )
    if SUBAGENT_CALL not in seen:
        return response_events(
            call_item(
                "subagent",
                SUBAGENT_CALL,
                {
                    "description": "probe the gate",
                    "prompt": "Try to run a shell command, then report what happened.",
                },
            ),
            tag,
        )
    if MCP_CALL not in seen:
        return response_events(
            call_item(mcp_tool_name(catalog_names(request)), MCP_CALL, {"command": "ls /"}), tag
        )
    return response_events(message_item(FINAL_TEXT, f"msg_{tag}"), tag)


def run_graff(graff: Path, port: int, mcp_port: int, mode: str) -> list[dict]:
    """One `--json` one-shot turn; returns the emitted JSONL events.

    `mode` is "flag" (--no-local-tools), "env" (GRAFF_NO_LOCAL_TOOLS=1) or
    "off" (the control run).
    """
    with tempfile.TemporaryDirectory(prefix="graff-no-local-tools-") as tmp:
        workspace = Path(tmp)
        codex_home = workspace / "codex-home"
        codex_home.mkdir()
        (codex_home / "auth.json").write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "no-local-tools-mock",
                        "account_id": "acct-no-local-tools",
                    }
                }
            ),
            encoding="utf-8",
        )
        (workspace / ".mcp.json").write_text(
            json.dumps(
                {"mcpServers": {"sandbox": {"url": f"http://127.0.0.1:{mcp_port}/mcp"}}},
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        settings = workspace / ".harness" / "settings.json"
        settings.parent.mkdir()
        settings.write_text(
            json.dumps({"skills": {"codedbpro": False, "muonry": False}}),
            encoding="utf-8",
        )

        env = os.environ.copy()
        for name in tuple(env):
            if name.startswith("GRAFF_") or name.startswith("CODEX_"):
                env.pop(name)
        env.update(
            {
                "HOME": tmp,
                "CODEX_HOME": str(codex_home),
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_BEHAVIOR_TRACE": "0",
            }
        )
        if mode == "env":
            env["GRAFF_NO_LOCAL_TOOLS"] = "1"
        argv = [str(graff), "--model", "codex", "--json", "--yolo", "--no-telemetry"]
        if mode == "flag":
            argv.append("--no-local-tools")
        completed = subprocess.run(
            argv,
            cwd=tmp,
            env=env,
            input=json.dumps({"type": "user", "text": "run the probe"}) + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                f"graff exited {completed.returncode}\n"
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
            )
        events = []
        for line in completed.stdout.splitlines():
            if line.strip():
                events.append(json.loads(line))
        return events


def tool_results(events: list[dict], name: str) -> list[dict]:
    return [
        e for e in events if e.get("type") == "tool_result" and e.get("name") == name
    ]


def assert_gated(requests: list[RecordedRequest], events: list[dict]) -> None:
    root = [r for r in requests if "load_tool_schemas" in tool_names(r)]
    child = [r for r in requests if "load_tool_schemas" not in tool_names(r)]
    if not root or not child:
        raise AssertionError(
            f"expected both root and child requests, saw {len(root)}/{len(child)}"
        )

    # Layer 1, root: nothing local advertised (wire OR the fold listing);
    # webfetch, orchestration and the MCP-sourced sandbox tool all survive.
    names = catalog_names(root[0])
    leaked = [n for n in names if n in GATED_TOOLS]
    if leaked:
        raise AssertionError(f"root catalog still advertises {leaked!r}")
    for expected in ("webfetch", "subagent", "workflow", "todo_write"):
        if expected not in names:
            raise AssertionError(f"root catalog lost {expected}: {names!r}")
    mcp_tool_name(names)

    # Layer 1, child: subagents inherit the gate (their catalogs are not folded).
    child_names = tool_names(child[0])
    child_leaked = [n for n in child_names if n in GATED_TOOLS]
    if child_leaked:
        raise AssertionError(f"subagent catalog still advertises {child_leaked!r}")
    if "webfetch" not in child_names:
        raise AssertionError(f"subagent catalog lost webfetch: {child_names!r}")

    # Layer 2, root: the hallucinated bash call is refused, not run.
    results = tool_results(events, "bash")
    if len(results) != 1 or not results[0].get("is_error"):
        raise AssertionError(f"bash was not refused as a tool error: {results!r}")
    if "--no-local-tools" not in results[0].get("text", ""):
        raise AssertionError(f"refusal does not name the flag: {results[0]!r}")

    # Layer 2, child: the refusal is what the child's next request carries back.
    child_followups = [
        r for r in child if CHILD_BASH_CALL in json.dumps(r.body, separators=(",", ":"))
    ]
    if not child_followups:
        raise AssertionError("the child never reported its bash call back")
    followup = json.dumps(child_followups[0].body, separators=(",", ":"))
    if "--no-local-tools" not in followup:
        raise AssertionError(f"child bash call was not refused: {followup[:800]}")

    # Nothing executed: the marker never appears in any event or request body.
    haystack = json.dumps(events, separators=(",", ":")) + json.dumps(
        [r.body for r in requests], separators=(",", ":")
    )
    if ESCAPE_MARKER in haystack:
        raise AssertionError("the gated bash command actually ran")

    # MCP is unaffected: the sandbox tool ran and its output came back.
    mcp_results = [
        e
        for e in events
        if e.get("type") == "tool_result" and str(e.get("name", "")).startswith("mcp__")
    ]
    if len(mcp_results) != 1 or mcp_results[0].get("is_error"):
        raise AssertionError(f"the MCP sandbox tool did not run: {mcp_results!r}")
    if MCP_RESULT not in mcp_results[0].get("text", ""):
        raise AssertionError(f"MCP result text missing: {mcp_results[0]!r}")
    if not SandboxMcp.calls:
        raise AssertionError("the MCP server never received a tools/call")


def assert_control(requests: list[RecordedRequest], events: list[dict]) -> None:
    # monitor is folded: it is not a wire tool until load_tool_schemas, so
    # the control catalog is wire names plus the Folded native listing.
    names = catalog_names(requests[0])
    missing = [n for n in GATED_TOOLS if n not in names]
    if missing:
        raise AssertionError(f"ungated catalog is missing {missing!r}")
    results = tool_results(events, "bash")
    if len(results) != 1 or results[0].get("is_error"):
        raise AssertionError(f"ungated bash did not run: {results!r}")
    if ESCAPE_MARKER not in results[0].get("text", ""):
        raise AssertionError(f"ungated bash produced no output: {results[0]!r}")


def run(graff: Path) -> None:
    mcp_server = ThreadingHTTPServer(("127.0.0.1", 0), SandboxMcp)
    mcp_thread = threading.Thread(target=mcp_server.serve_forever, daemon=True)
    mcp_thread.start()
    try:
        for mode, label in (
            ("flag", "--no-local-tools: nothing local advertised, dispatch refused, MCP live"),
            ("env", "GRAFF_NO_LOCAL_TOOLS=1 gates the run exactly like the flag"),
            ("off", "control: the same scripted bash call runs without the gate"),
        ):
            SandboxMcp.calls = []
            mock = CodexMock(events_for_request=script)
            port = mock.start()
            try:
                events = run_graff(graff, port, mcp_server.server_port, mode)
                requests = mock.recorded_requests()
            finally:
                mock.stop()
            if mode == "off":
                assert_control(requests, events)
            else:
                assert_gated(requests, events)
            print(f"ok    {label}")
    finally:
        mcp_server.shutdown()
        mcp_server.server_close()
        mcp_thread.join(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    run(graff)
    print("--no-local-tools E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
