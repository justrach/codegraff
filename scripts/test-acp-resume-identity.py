#!/usr/bin/env python3
"""Offline ACP lifecycle for #1529: `/resume` moves a live session onto another
save. The prompt result names that save (`_meta["graff/durableSessionId"]`), a
restarted worker loads it, and the continued history comes back. Covers a plain
`/resume SOURCE` and an explicit `--branch DEST`."""
import importlib.util
import json
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

_spec = importlib.util.spec_from_file_location("acp_session_load_fixture", REPO / "scripts/test-acp-session-load.py")
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
Acp = _fixture.Acp


def prompt(client, sid, text):
    reply = client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]})
    assert "result" in reply, reply
    return reply["result"]


def saved_text(cwd, name):
    path = cwd / ".graff/sessions" / f"{name}.session.json"
    deadline = time.monotonic() + 5
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(.05)
    return path.read_text()


def replayed(client, start):
    out = []
    for event in client.events[start:]:
        update = event.get("params", {}).get("update", {})
        content = update.get("content", {})
        if isinstance(content, dict):
            out.append(content.get("text", ""))
    return "".join(out)


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-resume-identity-") as temporary:
        base = Path(temporary).resolve()
        cwd, home = base / "work", base / "home"
        cwd.mkdir()
        home.mkdir()
        model = ScriptedModel([
            {"text": "Baseline answer."},
            {"text": "Continued answer."},
            {"text": "Branch answer."},
            {"text": "After restart."},
        ])
        port = model.start(0)
        new = {"cwd": str(cwd), "mcpServers": []}

        # 1. A saved conversation to resume later.
        first = Acp(binary, cwd, home, port)
        try:
            first.request("initialize", {"protocolVersion": 1})
            baseline = first.request("session/new", new)["result"]["sessionId"]
            result = prompt(first, baseline, "Baseline question.")
            assert "_meta" not in result or "graff/durableSessionId" not in result["_meta"], result
        finally:
            first.close()
        assert "Baseline answer." in saved_text(cwd, baseline)

        # 2. A fresh session resumes it: the result names the save it now writes.
        second = Acp(binary, cwd, home, port)
        try:
            second.request("initialize", {"protocolVersion": 1})
            transport = second.request("session/new", new)["result"]["sessionId"]
            assert transport != baseline
            moved = prompt(second, transport, f"/resume {baseline}")
            assert moved.get("_meta", {}).get("graff/durableSessionId") == baseline, moved
            # The transport ID keeps routing this connection.
            continued = prompt(second, transport, "Continued question.")
            assert continued.get("_meta", {}).get("graff/durableSessionId") == baseline, continued
        finally:
            second.close()
        text = saved_text(cwd, baseline)
        assert "Continued question." in text and "Continued answer." in text

        # 3. A restarted worker loads the reported save and has the continued history.
        third = Acp(binary, cwd, home, port)
        try:
            third.request("initialize", {"protocolVersion": 1})
            third.request("session/new", new)
            start = len(third.events)
            loaded = third.request("session/load", {"sessionId": baseline, **new})
            assert "result" in loaded, loaded
            history = replayed(third, start)
            assert "Baseline question." in history and "Continued answer." in history, history

            # 4. An explicit branch destination is reported the same way.
            branched = prompt(third, baseline, f"/resume {baseline} --branch fork-1529")
            assert branched.get("_meta", {}).get("graff/durableSessionId") == "fork-1529", branched
            prompt(third, baseline, "Branch question.")
        finally:
            third.close()
        assert "Branch question." in saved_text(cwd, "fork-1529")
        assert "Branch question." not in saved_text(cwd, baseline), "a branch must not write its source"

        fourth = Acp(binary, cwd, home, port)
        try:
            fourth.request("initialize", {"protocolVersion": 1})
            fourth.request("session/new", new)
            loaded = fourth.request("session/load", {"sessionId": "fork-1529", **new})
            assert "result" in loaded, loaded
            after = prompt(fourth, "fork-1529", "One more.")
            assert "graff/durableSessionId" not in after.get("_meta", {}), "loaded save is the transport ID"
        finally:
            fourth.close()
        body = json.dumps(model.requests[-1])
        assert "Branch question." in body and "Continued answer." in body, "branch keeps the resumed history"
        print("ok: /resume reports its save; a restart restores the continued history (plain and --branch)")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
