#!/usr/bin/env python3
"""Offline two-process ACP v1 load: replay, context, and stale shell handles."""
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel


class Acp:
    def __init__(self, binary, cwd, home, port):
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "HARNESS_"))}
        env.update(HOME=str(home), AI_GATEWAY_API_KEY="local", GRAFF_FLEET="off",
                   GRAFF_VERCEL_URL=f"http://127.0.0.1:{port}/v1/chat/completions",
                   GRAFF_NO_TELEMETRY="1", GRAFF_NO_SMOLIFY="1",
                   GRAFF_BEHAVIOR_UPLOAD="off", NO_COLOR="1")
        self.err = open(cwd / f"acp-{time.time_ns()}.stderr", "w")
        self.proc = subprocess.Popen([str(binary), "acp", "--yolo", "--old", "--model", "vercel"],
                                     cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.err, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        self.pending = b""
        self.next_id = 0
        self.events = []

    def request(self, method, params=None, timeout=25):
        self.next_id += 1
        target = self.next_id
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": target, "method": method,
                                           "params": params or {}}) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" not in self.pending:
                if not self.selector.select(.1):
                    continue
                chunk = os.read(self.proc.stdout.fileno(), 65536)
                if not chunk:
                    raise AssertionError(f"ACP exited during {method}")
                self.pending += chunk
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                item = json.loads(line)
                self.events.append(item)
                if item.get("id") == target:
                    return item
        raise AssertionError(f"ACP {method} timed out")

    def close(self):
        self.selector.close()
        if self.proc.poll() is None:
            self.proc.stdin.close()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            if self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(timeout=3)
        self.err.close()


def tool_text(body):
    return [m.get("content", "") for m in body.get("messages", []) if m.get("role") == "tool"]


class FollowingModel(ScriptedModel):
    def __init__(self, old_handle):
        super().__init__([])
        self.old_handle = old_handle
        self.new_handle = None
        self.stale_output = ""
        self.stale_kill = ""
        self.new_output = ""

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            n = len(self.requests)
        if n == 1:
            return {"tool": "shell", "arguments": {"action": "run", "command": "sleep 5", "run_in_background": True}}
        if n == 2:
            found = re.search(r"\[job (\d+) started:", tool_text(body)[-1])
            assert found, "new background job handle missing"
            self.new_handle = int(found.group(1))
            return {"tool": "bash_output", "arguments": {"id": self.old_handle, "wait_ms": 0}}
        if n == 3:
            self.stale_output = tool_text(body)[-1]
            return {"tool": "bash_kill", "arguments": {"id": self.old_handle}}
        if n == 4:
            self.stale_kill = tool_text(body)[-1]
            return {"tool": "bash_output", "arguments": {"id": self.new_handle, "wait_ms": 0}}
        if n == 5:
            self.new_output = tool_text(body)[-1]
            return {"text": "Loaded context remains available."}
        return {"text": "done"}


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-load-") as temporary:
        cwd = Path(temporary)
        home = cwd / "home"
        home.mkdir()
        first_model = ScriptedModel([
            {"tool": "shell", "arguments": {"action": "run", "command": "sleep 5", "run_in_background": True}},
            {"text": "Original assistant answer."},
        ])
        first_port = first_model.start(0)
        a = Acp(binary, cwd, home, first_port)
        try:
            init = a.request("initialize", {"protocolVersion": 1})
            assert init["result"]["agentCapabilities"]["loadSession"] is True
            sid = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]
            assert "/" not in sid and "\\" not in sid
            changed = a.request("session/set_config_option", {"sessionId": sid, "configId": "thought_level", "value": "high"})
            assert changed["result"]["configOptions"][0]["currentValue"] == "high"
            duplicate = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})
            assert duplicate["error"]["code"] == -32000
            turn = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "Original human request."}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn"
            old_result = tool_text(first_model.requests[1])[-1]
            old = int(re.search(r"\[job (\d+) started:", old_result).group(1))
            saved = cwd / ".graff" / "sessions" / f"{sid}.session.json"
            end = time.monotonic() + 5
            while not saved.exists() and time.monotonic() < end:
                time.sleep(.05)
            assert saved.exists(), "ACP session ID is not the durable save basename"
        finally:
            a.close()
            first_model.stop()

        # Simulate a compacted provider window: the transcript still retains
        # an older user turn that no longer appears in the model snapshot.
        transcript = cwd / ".graff" / "sessions" / f"{sid}.transcript.jsonl"
        assert transcript.exists()
        transcript.write_text(json.dumps({"role": "user", "content": "Older retained request."}) + "\n" + transcript.read_text())

        next_model = FollowingModel(old)
        second_port = next_model.start(0)
        b = Acp(binary, cwd, home, second_port)
        try:
            b.request("initialize", {"protocolVersion": 1})
            created = b.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]
            fresh = created["sessionId"]
            assert fresh != sid
            lowered = b.request("session/set_config_option", {"sessionId": fresh, "configId": "thought_level", "value": "low"})
            assert lowered["result"]["configOptions"][0]["currentValue"] == "low"
            bad = b.request("session/load", {"sessionId": "../escape", "cwd": str(cwd), "mcpServers": []})
            assert bad["error"]["code"] == -32602
            missing = b.request("session/load", {"sessionId": "missing", "cwd": str(cwd), "mcpServers": []})
            assert missing["error"]["code"] == -32602
            corrupt = cwd / ".graff" / "sessions" / "corrupt.session.json"
            corrupt.write_text('{"provider":42,"model":"mock","messages":[]}')
            invalid = b.request("session/load", {"sessionId": "corrupt", "cwd": str(cwd), "mcpServers": []})
            assert invalid["error"]["code"] == -32602
            wrong = b.request("session/load", {"sessionId": sid, "cwd": str(home), "mcpServers": []})
            assert wrong["error"]["code"] == -32602
            before = len(b.events)
            loaded = b.request("session/load", {"sessionId": sid, "cwd": str(cwd), "mcpServers": []})
            created_config = created["configOptions"]
            loaded_config = loaded["result"]["configOptions"]
            assert len(created_config) == len(loaded_config) == 1, (created, loaded)
            assert created_config[0]["category"] == loaded_config[0]["category"] == "thought_level"
            assert created_config[0]["currentValue"] == "high", created_config
            assert loaded_config[0]["currentValue"] == "low", loaded_config
            duplicate_after_load = b.request("session/new", {"cwd": str(cwd), "mcpServers": []})
            assert duplicate_after_load["error"]["code"] == -32000
            replay = b.events[before:]
            updates = [event["params"]["update"] for event in replay if event.get("method") == "session/update"]
            assert any(u.get("sessionUpdate") == "user_message_chunk" and u["content"].get("text") == "Original human request." for u in updates)
            assert any(u.get("sessionUpdate") == "user_message_chunk" and u["content"].get("text") == "Older retained request." for u in updates)
            assert any(u.get("sessionUpdate") == "agent_message_chunk" and u["content"].get("text") == "Original assistant answer." for u in updates)
            assert any(u.get("sessionUpdate") == "tool_call" for u in updates)
            assert any(u.get("sessionUpdate") == "tool_call_update" and u.get("status") == "completed" for u in updates)
            stale_session = b.request("session/prompt", {"sessionId": fresh, "prompt": [{"type": "text", "text": "Wrong session."}]})
            assert stale_session["error"]["code"] == -32602
            continued = b.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "Continue with original context."}]}, 35)
            assert continued["result"]["stopReason"] == "end_turn"
            assert next_model.requests[0]["reasoning"]["effort"] == "low"
            assert next_model.new_handle != old
            assert "Original human request." in json.dumps(next_model.requests[0])
            assert "Original assistant answer." in json.dumps(next_model.requests[0])
            assert re.search(r"unknown|stale|no background job|interrupted", next_model.stale_output, re.I)
            assert re.search(r"unknown|stale|no background job|interrupted", next_model.stale_kill, re.I)
            assert str(next_model.new_handle) not in next_model.stale_output
            assert not re.search(r"unknown|stale|no background job|interrupted", next_model.new_output, re.I)
        finally:
            b.close()
            next_model.stop()
    print("ACP session/load replay and stale shell isolation: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
