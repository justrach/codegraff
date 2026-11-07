#!/usr/bin/env python3
"""Offline #1701: real ACP and line REPL deliver the same /issue brief.

Run against an already-built binary (this script never builds):
  python3 scripts/test-issue-acp.py ./zig-out/bin/graff
All model requests use a temporary mocklocal router and loopback transport.
The scripted model never requests tools; no GitHub operations are performed.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))
from mock_model import ScriptedModel  # noqa: E402

REPORT = "fixture recurrence"
REPLY = "Offline issue routing checked."


def multiline(expression: str) -> str:
    """Read only Zig multiline literals, preserving their exact line breaks."""
    return "\n".join(line.lstrip()[2:] for line in expression.splitlines()
                     if line.lstrip().startswith("\\\\"))


def expected_user_text(report: str) -> str:
    # Compare the entire model-visible brief, not just one policy substring or
    # system-prompt text (which also carries the shared lifecycle guidance).
    source = (ROOT / "src" / "issue_cmd.zig").read_text()
    expression = source.split("pub const brief =", 1)[1].split("\n;", 1)[0]
    before, after = expression.split('++ @import("issue_reporting.zig").guidance ++')
    shared = (ROOT / "src" / "issue_reporting.zig").read_text()
    guidance = multiline(shared.split("pub const guidance =", 1)[1].split("\n;", 1)[0])
    assert "A comment alone does not complete a recurrence report." in guidance
    brief = multiline(before) + guidance + multiline(after)
    return f"{brief}\n\nReport: {report}"


def environment(workspace: Path, port: int) -> dict[str, str]:
    # Do not inherit credentials, provider overrides, hooks, or real HOME state.
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG")
           if key in os.environ}
    config = workspace / ".graff"
    config.mkdir()
    (config / ".config.router").write_text(json.dumps({
        "id": "mocklocal", "base_url": f"http://127.0.0.1:{port}/v1",
        "env_key": "MOCKLOCAL_API_KEY", "default_model": "mock",
    }))
    mcp = workspace / "mcp.json"
    mcp.write_text('{"mcpServers":{}}')
    settings = workspace / ".harness"
    settings.mkdir()
    (settings / "settings.json").write_text(json.dumps({"ai_title": False}))
    env.update(HOME=str(workspace), MOCKLOCAL_API_KEY="local",
               GRAFF_MCP_CONFIG=str(mcp), GRAFF_NO_TELEMETRY="1",
               GRAFF_BEHAVIOR_UPLOAD="off", GRAFF_FLEET="off",
               GRAFF_LEARN_AUTO="off", GRAFF_NO_SMOLIFY="1",
               GRAFF_NO_CODEDB_GUARD="1", NO_COLOR="1")
    return env


def last_user(request: dict) -> str:
    messages = [message for message in request["messages"]
                if message.get("role") == "user"]
    assert messages, "Model request has no user message"
    content = messages[-1]["content"]
    if isinstance(content, str):
        return content
    return "".join(part.get("text", "") for part in content)


def terminate(process: subprocess.Popen) -> None:
    if process.poll() is None:
        try:
            if os.name == "nt":
                process.terminate()
            else:
                os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
    for pipe in (process.stdin, process.stdout):
        if pipe:
            pipe.close()


def acp(binary: Path, model: ScriptedModel, workspace: Path, env: dict) -> str:
    process = subprocess.Popen(
        [str(binary), "acp", "--model", "mocklocal/mock", "--old", "--yolo",
         "--no-lean", "--no-telemetry"], cwd=workspace, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, start_new_session=True,
    )
    events = queue.Queue()

    def read() -> None:
        for line in process.stdout:
            try:
                events.put(json.loads(line))
            except ValueError:
                pass
        events.put(None)

    threading.Thread(target=read, daemon=True).start()
    identifier = 0

    def call(method: str, params: dict) -> tuple[dict, list[dict]]:
        nonlocal identifier
        identifier += 1
        process.stdin.write(json.dumps(dict(jsonrpc="2.0", id=identifier,
                                           method=method, params=params)) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 30
        updates = []
        while True:
            value = events.get(timeout=max(0.01, deadline - time.monotonic()))
            assert value is not None, "ACP stopped before its response"
            if value.get("id") == identifier:
                assert "error" not in value, value
                return value, updates
            updates.append(value)

    try:
        call("initialize", {"protocolVersion": 1})
        session, _ = call("session/new", {"cwd": str(workspace), "mcpServers": []})
        sid = session["result"]["sessionId"]

        def prompt(text: str) -> list[dict]:
            response, updates = call("session/prompt", {
                "sessionId": sid, "prompt": [{"type": "text", "text": text}],
            })
            assert response["result"]["stopReason"] == "end_turn", response
            return updates

        for bare in ("/issue", "/issue   "):
            before = len(model.requests)
            updates = prompt(bare)
            assert len(model.requests) == before, "Bare /issue started a model turn"
            assert "usage: /issue <what went wrong>" in json.dumps(updates), updates

        before = len(model.requests)
        prompt(f"/issue {REPORT}")
        assert len(model.requests) == before + 1, "Expected exactly one /issue model turn"
        expanded = last_user(model.requests[-1])
        assert expanded == expected_user_text(REPORT), expanded
        assert not expanded.startswith("/issue"), "Literal command reached the model"

        before = len(model.requests)
        prompt(REPORT)
        assert len(model.requests) == before + 1
        assert last_user(model.requests[-1]) == REPORT, "Plain report was expanded"

        before = len(model.requests)
        prompt("/issue   fixture whitespace\nsecond line   ")
        assert len(model.requests) == before + 1
        assert last_user(model.requests[-1]) == expected_user_text(
            "fixture whitespace\nsecond line")

        # A nested command in a review target is still review input, not an
        # issue report. Review remains higher priority and isolated.
        before = len(model.requests)
        prompt("/review /issue review-fixture")
        assert len(model.requests) == before + 1
        assert last_user(model.requests[-1]) == "/issue review-fixture"
        assert "Perform one read-only, defect-first review pass" in json.dumps(
            model.requests[-1])
        return expanded
    finally:
        terminate(process)


def repl(binary: Path, model: ScriptedModel, workspace: Path, env: dict) -> str:
    before = len(model.requests)
    # This is the actual line dispatcher, deliberately NOT --json or -p:
    # those surfaces treat slash input differently and would not prove parity.
    process = subprocess.Popen(
        [str(binary), "--model", "mocklocal/mock", "--old", "--yolo",
         "--no-lean", "--no-telemetry"], cwd=workspace, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(f"/issue {REPORT}\n/quit\n", timeout=45)
        assert process.returncode == 0, stderr
        assert REPLY in stdout + stderr, "Line REPL did not display the scripted reply"
        assert len(model.requests) == before + 1, "Expected one REPL model turn"
        return last_user(model.requests[-1])
    finally:
        terminate(process)
        if process.stderr:
            process.stderr.close()


def main() -> None:
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "zig-out/bin/graff").resolve()
    assert binary.is_file(), f"Build the binary separately before running: {binary}"
    model = ScriptedModel([], exhausted_text=REPLY)
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-issue-acp-") as temp:
            workspace = Path(temp)
            acp_workspace = workspace / "acp"
            repl_workspace = workspace / "repl"
            acp_workspace.mkdir()
            repl_workspace.mkdir()
            acp_text = acp(binary, model, acp_workspace, environment(acp_workspace, port))
            repl_text = repl(binary, model, repl_workspace, environment(repl_workspace, port))
            assert acp_text == repl_text == expected_user_text(REPORT)
        print("PASS /issue ACP/REPL full brief and lifecycle parity; bare usage, "
              "plain report, whitespace and review precedence")
    finally:
        model.stop()


if __name__ == "__main__":
    main()
