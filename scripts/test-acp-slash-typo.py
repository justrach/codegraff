#!/usr/bin/env python3
"""Offline ACP slash parity (#1275): a mistyped `/command` is answered locally
with the terminal's refusal and nearest spelling, exactly like the TUI refuses
it, and never costs a model turn. Paths and prose still reach the model."""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts/eval"))
from mock_model import ScriptedModel

_spec = importlib.util.spec_from_file_location("acp_session_load_fixture", REPO / "scripts/test-acp-session-load.py")
_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixture)
Acp = _fixture.Acp


def reply_text(a, start):
    """Concatenated agent_message_chunk text among events recorded since `start`."""
    out = []
    for e in a.events[start:]:
        update = e.get("params", {}).get("update", {})
        if update.get("sessionUpdate") == "agent_message_chunk":
            out.append(update.get("content", {}).get("text", ""))
    return "".join(out)


def run(binary):
    with tempfile.TemporaryDirectory(prefix="graff-acp-slash-typo-") as temporary:
        base = Path(temporary).resolve()
        cwd, home = base / "work", base / "home"
        cwd.mkdir()
        home.mkdir()
        model = ScriptedModel([{"text": "path prompt answered"}])
        port = model.start(0)
        a = Acp(binary, cwd, home, port)
        try:
            a.request("initialize", {"protocolVersion": 1})
            sid = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]

            def prompt(text):
                start = len(a.events)
                turn = a.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}, 35)
                assert turn["result"]["stopReason"] == "end_turn", turn
                return reply_text(a, start)

            typo = prompt("/resuem")
            assert "unknown command '/resuem'" in typo and "did you mean /resume?" in typo, typo
            far = prompt("/xyzzy now")
            assert "unknown command '/xyzzy'" in far and "/help for the list" in far, far
            assert model.requests == [], "a mistyped command must never reach the model"

            passed = prompt("/tmp/x.png what is in this file?")
            assert "path prompt answered" in passed, passed
            assert len(model.requests) == 1, len(model.requests)
            assert "/tmp/x.png what is in this file?" in json.dumps(model.requests[0]["messages"][-1])
        finally:
            a.close()
            model.stop()
    print("ACP slash typo: answered locally with a suggestion, no model call; paths still reach the model: ok")


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve())
