#!/usr/bin/env python3
"""Offline MCP smoke test: real stdio server and child, local scripted model."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / "eval"))
from mock_model import ScriptedModel


def request(method, params=None, ident=None):
    obj = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        obj["params"] = params
    if ident is not None:
        obj["id"] = ident
    return json.dumps(obj) + "\n"


def exchange(exe, env, cwd, messages, extra=()):
    run = subprocess.run(
        [exe, "mcp", "serve", *extra], input=messages, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd,
        timeout=45,
    )
    assert run.returncode == 0, run.stderr
    return [json.loads(line) for line in run.stdout.splitlines()]


def main():
    exe = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve())
    handshake = request("initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "offline-test", "version": "1"},
    }, 1) + request("notifications/initialized")
    with tempfile.TemporaryDirectory(prefix="graff-mcp-test-") as workspace:
        env = {
            "PATH": os.environ.get("PATH", ""), "HOME": workspace,
            "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off",
            "GRAFF_NO_PLUGINS": "1", "GRAFF_NO_SMOLIFY": "1", "NO_COLOR": "1",
        }
        replies = exchange(exe, env, workspace, handshake + request("tools/list", {}, 2))
        assert replies[0]["result"]["capabilities"]["tools"] == {}
        assert replies[1]["result"]["tools"][0]["name"] == "run_task"
        assert "_meta" not in replies[1]["result"]["tools"][0]
        app_handshake = request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {"extensions": {"io.modelcontextprotocol/ui": {
                "mimeTypes": ["text/html;profile=mcp-app"],
            }}}, "clientInfo": {"name": "offline-app-test", "version": "1"},
        }, 1) + request("notifications/initialized")
        replies = exchange(exe, env, workspace, app_handshake +
            request("tools/list", {}, 2) + request("resources/list", {}, 3) +
            request("resources/read", {"uri": "ui://codegraff/task-result"}, 4) +
            request("resources/read", {"uri": "file:///unavailable"}, 5) +
            request("resources/templates/list", {}, 6))
        tool = replies[1]["result"]["tools"][0]
        assert tool["_meta"]["ui"]["resourceUri"] == "ui://codegraff/task-result"
        assert tool["_meta"]["ui"]["visibility"] == ["model"]
        resource = replies[3]["result"]["contents"][0]
        assert replies[2]["result"]["resources"][0]["uri"] == resource["uri"]
        assert resource["mimeType"] == "text/html;profile=mcp-app"
        assert resource["text"] == (Path(__file__).resolve().parent.parent / "src/mcp_task_app.html").read_text().replace("/* CODEGRAFF_THEME */", (Path(__file__).resolve().parent.parent / "apps/native/app/ui-theme.css").read_text())
        assert resource["_meta"]["ui"]["csp"]["connectDomains"] == []
        assert replies[4]["error"]["code"] == -32002
        assert replies[5]["result"]["resourceTemplates"] == []
        # The real one-shot may request a second final to reconcile a prose-only
        # first turn. Both scripted replies are deterministic and offline.
        model = ScriptedModel([{"text": "MCP_TASK_OK"}] * 8, exhausted_text="MCP_TASK_OK")
        model.start(1234)
        try:
            env["LMSTUDIO_API_KEY"] = "local"
            call = request("tools/call", {"name": "run_task", "arguments": {
                "prompt": "Reply with MCP_TASK_OK. This is a greeting; no files or tools are needed.",
                "timeout_seconds": 20, "max_model_calls": 8,
            }}, "task")
            replies = exchange(exe, env, workspace, handshake + call + request("ping", {}, 3), ("--model", "lmstudio"))
            assert replies[1]["id"] == "task"
            result = replies[1]["result"]
            assert not result["isError"], result
            assert "MCP_TASK_OK" in result["content"][0]["text"], result
            assert result["structuredContent"]["status"] == "completed"
            assert result["structuredContent"]["text"] == result["content"][0]["text"]
            assert result["structuredContent"]["timeout_seconds"] == 20
            assert replies[2]["result"] == {}
            assert model.requests, "task never reached the scripted model"
        finally:
            model.stop()
        for yolo in (False, True):
            target = Path(workspace) / "permission-check.txt"
            model = ScriptedModel([
                {"tool": "write_file", "arguments": {"path": "permission-check.txt", "content": "MCP_EDIT_OK"}},
                {"text": "Permission check complete."},
            ])
            model.start(1234)
            try:
                call = request("tools/call", {"name": "run_task", "arguments": {
                    "prompt": "Write permission-check.txt containing MCP_EDIT_OK.",
                    "timeout_seconds": 20,
                }}, 2)
                extra = ("--model", "lmstudio") + (("--yolo",) if yolo else ())
                exchange(exe, env, workspace, handshake + call, extra)
                assert target.exists() == yolo, f"server permission mode did not govern file writes (yolo={yolo})"
                assert model.requests, "permission fixture never reached the model"
                if yolo:
                    assert target.read_text() == "MCP_EDIT_OK"
            finally:
                model.stop()
        nested = dict(env, GRAFF_MCP_TASK="1")
        run = subprocess.run([exe, "mcp", "serve"], input="", text=True,
                             capture_output=True, env=nested, cwd=workspace, timeout=10)
        assert run.returncode != 0
        assert not run.stdout
    print("MCP server: discovery, app negotiation and resources, structured results, real task, permission modes, ping, recursion guard passed")


if __name__ == "__main__":
    main()
