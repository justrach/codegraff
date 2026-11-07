#!/usr/bin/env python3
"""Offline ACP session/fork: the branch carries the history, the source save
stays as it was, and a fresh process can fork a saved session."""
import importlib.util
import json
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

spec = importlib.util.spec_from_file_location("acp_load", REPO / "scripts/test-acp-session-load.py")
acp_load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acp_load)
Acp = acp_load.Acp


def wait_for(path, needle, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists() and needle in path.read_text():
            return
        time.sleep(.05)
    raise AssertionError(f"{path.name} never contained {needle!r}")


def updates(events):
    return [e["params"]["update"] for e in events if e.get("method") == "session/update"]


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-fork-") as temporary:
        cwd = Path(temporary).resolve()
        home = cwd / "home"
        home.mkdir()
        sessions = cwd / ".graff" / "sessions"

        model = ScriptedModel([{"text": "Original answer."}, {"text": "Branch answer."}])
        port = model.start(0)
        a = Acp(binary, cwd, home, port)
        try:
            init = a.request("initialize", {"protocolVersion": 1})
            assert init["result"]["agentCapabilities"]["sessionCapabilities"] == {"fork": {}}, init
            sid = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]
            empty = a.request("session/fork", {"sessionId": sid, "cwd": str(cwd), "mcpServers": []})
            assert empty["error"]["code"] == -32602, empty
            turn = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "Original request."}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            source = sessions / f"{sid}.session.json"
            wait_for(source, "Original answer.")

            # Same process: fork the live session and continue on the branch.
            forked = a.request("session/fork", {"sessionId": sid, "cwd": str(cwd), "mcpServers": []})
            branch = forked["result"]["sessionId"]
            assert branch == f"{sid}-fork-1", forked
            assert forked["result"]["configOptions"], forked
            before = source.read_text()
            stale = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "x"}]})
            assert stale["error"]["code"] == -32602, stale
            turn = a.request("session/prompt", {"sessionId": branch, "prompt": [{"type": "text", "text": "Branch request."}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            sent = json.dumps(model.requests[-1])
            assert "Original request." in sent and "Original answer." in sent, "branch lost the history"
            branch_save = sessions / f"{branch}.session.json"
            wait_for(branch_save, "Branch answer.")
            saved = json.loads(branch_save.read_text())
            assert saved.get("parent") == sid, saved.get("parent")
            assert source.read_text() == before, "a branch turn rewrote the source"
            assert "Branch request." not in source.read_text()
        finally:
            a.close()
            model.stop()

        # A fresh process forks the saved source and replays it on request.
        model = ScriptedModel([{"text": "Second branch answer."}])
        port = model.start(0)
        b = Acp(binary, cwd, home, port)
        try:
            b.request("initialize", {"protocolVersion": 1})
            missing = b.request("session/fork", {"sessionId": "missing", "cwd": str(cwd), "mcpServers": []})
            assert missing["error"]["code"] == -32602, missing
            escape = b.request("session/fork", {"sessionId": "../escape", "cwd": str(cwd), "mcpServers": []})
            assert escape["error"]["code"] == -32602, escape
            mark = len(b.events)
            forked = b.request("session/fork", {"sessionId": sid, "cwd": str(cwd), "mcpServers": [],
                                                "replayFrom": {"type": "start"}})
            second = forked["result"]["sessionId"]
            assert second == f"{sid}-fork-2", forked
            replayed = updates(b.events[mark:])
            assert any(u.get("sessionUpdate") == "user_message_chunk" and u["content"].get("text") == "Original request." for u in replayed)
            assert not any(u.get("sessionUpdate") == "user_message_chunk" and u["content"].get("text") == "Branch request." for u in replayed)
            turn = b.request("session/prompt", {"sessionId": second, "prompt": [{"type": "text", "text": "Second branch request."}]}, 35)
            assert turn["result"]["stopReason"] == "end_turn", turn
            sent = json.dumps(model.requests[-1])
            assert "Original answer." in sent and "Branch request." not in sent, "second branch saw the wrong history"
            wait_for(sessions / f"{second}.session.json", "Second branch answer.")
            assert source.read_text() == before, "forking from disk rewrote the source"
        finally:
            b.close()
            model.stop()
    print("ACP session/fork: live and saved forks keep history and leave the source untouched: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
