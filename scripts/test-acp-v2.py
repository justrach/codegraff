#!/usr/bin/env python3
"""ACP v2 (GRAFF_ACP_V2=1) wire shapes over a real `graff acp` process, and
v1 staying byte-compatible when the gate is closed."""
import json
import os
import selectors
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class Acp:
    def __init__(self, binary, root, v2):
        env = {"HOME": str(root), "PATH": "/usr/bin:/bin", "TERM": "dumb",
               "LMSTUDIO_API_KEY": "fixture", "GRAFF_NO_ADOPT": "1",
               "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"}
        if v2:
            env["GRAFF_ACP_V2"] = "1"
        self.child = subprocess.Popen([str(binary), "acp", "--yolo", "--model", "lmstudio"],
                                      cwd=root, env=env, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.poll = selectors.DefaultSelector()
        self.poll.register(self.child.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.seen = []

    def send(self, message):
        self.child.stdin.write((json.dumps(message) + "\n").encode())
        self.child.stdin.flush()

    def until(self, done, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)  # stdout must stay protocol-clean
                self.seen.append(message)
                if done(message):
                    return message
            if self.poll.select(.1):
                chunk = os.read(self.child.stdout.fileno(), 65536)
                assert chunk, "ACP exited early"
                self.buffer += chunk
        raise AssertionError("timed out; saw:\n" + "\n".join(json.dumps(m) for m in self.seen[-20:]))

    def close(self):
        self.poll.close()
        self.child.kill()
        self.child.wait()


def updates(seen, kind):
    return [m["params"]["update"] for m in seen
            if m.get("method") == "session/update" and m["params"]["update"].get("sessionUpdate") == kind]


def v2(binary, root):
    acp = Acp(binary, root, True)
    try:
        acp.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": 2, "capabilities": {"auth": {"terminal": {}}},
            "info": {"name": "v2-test", "version": "1"}}})
        init = acp.until(lambda m: m.get("id") == 1)["result"]
        assert init["protocolVersion"] == 2, init
        assert "agentCapabilities" not in init and "agentInfo" not in init, init
        assert init["capabilities"]["session"]["mcp"] == {"stdio": {}, "http": {}}, init
        assert init["info"]["name"] == "graff", init
        assert init["authMethods"][0]["methodId"] == "graff-login", init
        acp.send({"jsonrpc": "2.0", "id": 2, "method": "session/new",
                  "params": {"cwd": str(root), "mcpServers": []}})
        sid = acp.until(lambda m: m.get("id") == 2)["result"]["sessionId"]
        # A local slash command inserts a user message without a model call.
        acp.send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                  "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "/help"}]}})
        acp.until(lambda m: m.get("method") == "session/update"
                  and m["params"]["update"].get("sessionUpdate") == "state_update"
                  and m["params"]["update"].get("state") == "idle")
        ack = next(m for m in acp.seen if m.get("id") == 3)
        message_id = ack["result"]["messageId"]
        assert list(ack["result"]) == ["messageId"], ack
        users = updates(acp.seen, "user_message")
        assert users and users[-1]["messageId"] == message_id, users
        assert users[-1]["content"] == [{"type": "text", "text": "/help"}], users
        states = [(u["state"], u.get("stopReason")) for u in updates(acp.seen, "state_update")]
        assert states == [("running", None), ("idle", "end_turn")], states
        chunks = updates(acp.seen, "agent_message_chunk")
        assert chunks and all(c.get("messageId") for c in chunks), chunks
        names = {m["params"]["update"]["sessionUpdate"] for m in acp.seen if m.get("method") == "session/update"}
        assert not {n for n in names if n.startswith("gui_")}, names
        order = [i for i, m in enumerate(acp.seen) if m.get("id") == 3
                 or (m.get("method") == "session/update" and m["params"]["update"].get("state") == "idle")]
        assert order == sorted(order) and len(order) == 2, "prompt ack must precede idle"
        acp.send({"jsonrpc": "2.0", "id": 4, "method": "session/close", "params": {"sessionId": sid}})
        closed = acp.until(lambda m: m.get("id") == 4)
        assert closed.get("result") == {}, closed
    finally:
        acp.close()


def v1(binary, root):
    acp = Acp(binary, root, False)
    try:
        acp.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 2}})
        init = acp.until(lambda m: m.get("id") == 1)["result"]
        assert init["protocolVersion"] == 1 and "agentCapabilities" in init, init
        acp.send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": str(root), "mcpServers": []}})
        sid = acp.until(lambda m: m.get("id") == 2)["result"]["sessionId"]
        acp.send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                  "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "/help"}]}})
        done = acp.until(lambda m: m.get("id") == 3)
        assert done["result"] == {"stopReason": "end_turn"}, done
        assert not updates(acp.seen, "state_update") and not updates(acp.seen, "user_message")
        assert all("messageId" not in c for c in updates(acp.seen, "agent_message_chunk"))
    finally:
        acp.close()


def main():
    if os.name != "posix":
        print("ACP v2 wire integration: POSIX only")
        return
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff").resolve()
    with tempfile.TemporaryDirectory(prefix="graff-acp-v2-") as temporary:
        v2(binary, Path(temporary).resolve())
    with tempfile.TemporaryDirectory(prefix="graff-acp-v1-") as temporary:
        v1(binary, Path(temporary).resolve())
    print("ACP v2 wire integration: ok")


if __name__ == "__main__":
    main()
