#!/usr/bin/env python3
"""#1686: a reloaded ACP session keeps the provider's count of its compaction state.

For each first-party OpenAI Responses route (codex over SSE, chatgpt-new over
its default WebSocket transport), against a scripted loopback mock:

1. process A: the first reply carries an 8 MB opaque compaction item and the
   mock reports 80,000 input tokens; one warm follow-up lets graff count it;
2. process B: a NEW graff process loads the session, `/help` (no model call)
   reports the restored meter, then one ordinary prompt runs.

Asserted: the saved session records the count; the restored meter stays at
the counted ~80k instead of bytes/16 (~508k, 188% of the window); the
prompt after reload needs no forced compaction (threshold 1000); and the wire
follows OpenAI's compaction guide (store=false, the compaction item replayed
as-is). Offline: fake credentials, no provider calls.

Usage: python3 scripts/test-acp-reload-compaction-count.py [path/to/graff]
"""
import json, os, queue, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
from codex_ws_mock import CodexMock  # noqa: E402

GRAFF = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve()
BLOB = "A" * 8_000_000
USAGE = {"input_tokens": 80_000, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1, "total_tokens": 80_001}


def threshold(body):
    for cm in body.get("context_management") or []:
        if isinstance(cm, dict) and cm.get("type") == "compaction":
            return cm.get("compact_threshold")
    return None


class Script:
    """The mock emits the state once (as an in-stream compaction would), then plain replies."""

    def __init__(self):
        self.emitted = False

    def __call__(self, req):
        n = req.ordinal
        compaction = {"type": "compaction", "id": "cmp_1", "encrypted_content": BLOB}
        reply = {"type": "message", "id": f"msg_{n}", "status": "completed", "role": "assistant",
                 "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        if threshold(req.body) == 1000:
            out = [compaction]
        elif not self.emitted:
            self.emitted = True
            out = [compaction, reply]
        else:
            out = [reply]
        events = [{"type": "response.output_item.done", "output_index": i, "item": it} for i, it in enumerate(out)]
        events.append({"type": "response.completed", "response": {"id": f"resp_{n}", "output": out, "usage": USAGE}})
        return events


class Acp:
    def __init__(self, cwd, env, model):
        self.err = open(cwd / f"acp-{time.time_ns()}.stderr", "w")
        self.proc = subprocess.Popen([str(GRAFF), "acp", "--yolo", "--model", model], cwd=cwd, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err,
                                     start_new_session=True)
        self.chunks, self.pending, self.next_id, self.events = queue.SimpleQueue(), b"", 0, []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while chunk := os.read(self.proc.stdout.fileno(), 1 << 20):
                self.chunks.put(chunk)
        except OSError:
            pass
        self.chunks.put(None)

    def request(self, method, params, timeout=90):
        self.next_id += 1
        target = self.next_id
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": target, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" not in self.pending:
                try:
                    chunk = self.chunks.get(timeout=.1)
                except queue.Empty:
                    continue
                if chunk is None:
                    raise AssertionError(f"ACP exited during {method}")
                self.pending += chunk
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                item = json.loads(line)
                self.events.append(item)
                if item.get("id") == target and "method" not in item:
                    return item
        raise AssertionError(f"ACP {method} timed out")

    def prompt(self, sid, text):
        mark = len(self.events)
        r = self.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
        assert (r.get("result") or {}).get("stopReason") == "end_turn", (text, r)
        return [(u.get("used"), u.get("size")) for e in self.events[mark:]
                for u in [((e.get("params") or {}).get("update") or {})] if u.get("sessionUpdate") == "usage_update"]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=5)
        self.err.close()


def run(route, tmp):
    script = Script()
    mock = CodexMock(events_for_request=script)
    port = mock.start()
    try:
        home, cwd = tmp / route / "home", tmp / route / "work"
        cwd.mkdir(parents=True)
        (home / ".harness").mkdir(parents=True)
        (home / ".harness" / "settings.json").write_text(json.dumps({"ai_title": False, "skills": {"codedbpro": False}}))
        (tmp / "mcp.json").write_text('{"mcpServers":{}}')
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY") and not k.startswith(("GRAFF_", "CODEX_", "HARNESS_"))}
        env.update(HOME=str(home), NO_COLOR="1", GRAFF_FLEET="off", GRAFF_NO_TELEMETRY="1", GRAFF_LEARN_AUTO="off",
                   GRAFF_BEHAVIOR_UPLOAD="off", GRAFF_MCP_CONFIG=str(tmp / "mcp.json"))
        if route == "codex":
            codex_home = home / "codex"
            codex_home.mkdir()
            (codex_home / "auth.json").write_text(json.dumps({"tokens": {"access_token": "mock", "account_id": "acct"}}))
            env.update(CODEX_HOME=str(codex_home), GRAFF_CODEX_WS="off",
                       GRAFF_CODEX_URL=f"http://127.0.0.1:{port}/backend-api/codex/responses")
            model = "codex/gpt-5.5"
        else:
            creds = home / ".graff" / "credentials"
            creds.mkdir(parents=True, mode=0o700)
            record = creds / "chatgpt-new.json"
            record.write_text(json.dumps({"access_token": "mock", "scopes": ["chatgpt.tokens.use.direct"],
                                          "expires_at": int(time.time()) + 86_400}))
            record.chmod(0o600)
            env.update(GRAFF_CHATGPT_URL=f"http://127.0.0.1:{port}/v1/responses")
            model = "chatgpt-new/gpt-6.1-sol"
        new = {"cwd": str(cwd), "mcpServers": []}

        a = Acp(cwd, env, model)
        a.request("initialize", {"protocolVersion": 1})
        sid = a.request("session/new", new)["result"]["sessionId"]
        a.prompt(sid, "start")
        warm = a.prompt(sid, "warm follow-up")
        a.close()
        saved = [json.loads(f.read_text()) for f in (cwd / ".graff" / "sessions").glob("*.session.json")]
        assert len(saved) == 1, saved
        count = saved[0].get("opaque_state_count") or {}
        assert count.get("state_bytes") == len(BLOB) and count.get("tokens", 0) > 0, count

        b = Acp(cwd, env, model)
        b.request("initialize", {"protocolVersion": 1})
        b.request("session/new", new)
        b.request("session/load", {"sessionId": sid, **new})
        before = len(mock.recorded_requests())
        restored = b.prompt(sid, "/help")
        assert len(mock.recorded_requests()) == before, "an informational command called the model"
        b.prompt(sid, "after reload")
        b.close()
        after = mock.recorded_requests()[before:]

        used, size = restored[-1]
        warm_used = warm[-1][0]
        assert used <= warm_used + 1_000, f"{route}: restored meter {used}/{size}, warm {warm_used} (bytes/16 would be ~508k)"
        assert not any(threshold(q.body) == 1000 for q in after), f"{route}: reload forced a compaction"
        assert len(after) == 1, f"{route}: {len(after)} requests after reload"
        for q in mock.recorded_requests():
            assert q.body.get("store") is False, (route, q.ordinal, q.body.get("store"))
            for item in q.body.get("input") or []:
                if isinstance(item, dict) and item.get("type") == "compaction":
                    assert item == {"type": "compaction", "id": "cmp_1", "encrypted_content": BLOB}, f"{route}: compaction item altered"
        print(f"ok {route}: warm {warm_used}/{size}, restored {used}/{size}, {len(after)} request after reload, no forced compaction")
    finally:
        mock.stop()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for route in ("codex", "chatgpt-new"):
            run(route, Path(tmp))


if __name__ == "__main__":
    main()
