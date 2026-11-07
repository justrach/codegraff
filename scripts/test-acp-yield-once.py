#!/usr/bin/env python3
"""#1615: a yield_turn handoff reaches an ACP client exactly once.

The handoff streams as text while yield_turn runs and is also the turn's
returned result; its tool row must still complete.

Offline: uses the tier-2 scripted model, an isolated workspace and no credentials.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "eval"))
from mock_model import ScriptedModel

TERMINAL = ("completed", "failed")


def main() -> None:
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
    model = ScriptedModel([
        {"tool": "todo_write", "arguments": {"todos": [{"content": "wait for the screenshot", "status": "in_progress"}]}},
        {"tool": "yield_turn", "arguments": {"message": "HANDOFF_ONCE: attach the screenshot and I will continue."}},
    ])
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-acp-yield-") as temp:
            workspace = Path(temp)
            env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "SystemRoot") if key in os.environ}
            config = workspace / "mcp.json"
            config.write_text('{"mcpServers":{}}')
            env.update({
                "HOME": temp,
                "AI_GATEWAY_API_KEY": "local",
                "GRAFF_VERCEL_URL": "http://127.0.0.1:%d/v1/chat/completions" % port,
                "GRAFF_MCP_CONFIG": str(config),
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "GRAFF_LEARN_AUTO": "0",
                "GRAFF_BEHAVIOR_UPLOAD": "0",
                "GRAFF_NO_BROWSER": "1",
                "NO_COLOR": "1",
            })
            settings = workspace / ".harness/settings.json"
            settings.parent.mkdir()
            settings.write_text('{"ai_title":false}')
            proc = subprocess.Popen(
                [binary, "--yolo", "--no-telemetry", "--model", "vercel", "--old", "--no-lean", "acp"],
                cwd=temp, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, encoding="utf-8",
            )
            responses = queue.Queue()

            def read_stdout() -> None:
                for line in proc.stdout:
                    try:
                        responses.put(json.loads(line))
                    except ValueError:
                        responses.put({"invalid_stdout": line})
                responses.put({"eof": True})

            reader = threading.Thread(target=read_stdout, daemon=True)
            reader.start()
            # Drain stderr while graff runs: an unread pipe fills (about 4 KB on Windows)
            # and blocks graff mid-write, which reads as a hung reply.
            stderr_lines: list = []
            stderr_reader = threading.Thread(target=lambda: stderr_lines.extend(proc.stderr), daemon=True)
            stderr_reader.start()

            def request(rpc_id: int, method: str, params: dict) -> list:
                proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params}) + "\n")
                proc.stdin.flush()
                events = []
                while True:
                    try:
                        event = responses.get(timeout=45)
                    except queue.Empty:
                        raise AssertionError("no reply to %s within 45s; graff stderr tail:\n%s" % (method, "".join(stderr_lines)[-3000:]))
                    assert "invalid_stdout" not in event and "eof" not in event, event
                    events.append(event)
                    if event.get("id") == rpc_id:
                        assert "error" not in event, event
                        return events

            try:
                request(1, "initialize", {"protocolVersion": 1})
                sid = request(2, "session/new", {"cwd": temp, "mcpServers": []})[-1]["result"]["sessionId"]
                events = request(3, "session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "fix the layout bug"}]})
                assert events[-1]["result"]["stopReason"] == "end_turn", events[-1]
                answer = "".join(e["params"]["update"]["content"]["text"] for e in events
                                 if e.get("method") == "session/update"
                                 and e["params"]["update"].get("sessionUpdate") == "agent_message_chunk")
                assert answer.count("HANDOFF_ONCE") == 1, "handoff delivered %d times: %r" % (answer.count("HANDOFF_ONCE"), answer)
                updates = [e["params"]["update"] for e in events
                           if e.get("method") == "session/update" and "toolCallId" in e["params"].get("update", {})]
                rows = {u["toolCallId"]: (u.get("_meta") or {}).get("graff/toolName") for u in updates
                        if u.get("sessionUpdate") == "tool_call"}
                for call_id, name in rows.items():
                    ends = [u for u in updates if u["toolCallId"] == call_id and u.get("status") in TERMINAL]
                    assert len(ends) == 1, "%s ended %d times" % (name, len(ends))
                proc.stdin.close()
                assert proc.wait(timeout=15) == 0, "".join(stderr_lines)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                reader.join(timeout=5)
                for pipe in (proc.stdin, proc.stdout, proc.stderr):
                    if pipe and not pipe.closed:
                        pipe.close()
    finally:
        model.stop()
    print("ACP yield_turn: the handoff arrives once and its row completes")


if __name__ == "__main__":
    main()
