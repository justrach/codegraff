#!/usr/bin/env python3
"""Offline ACP slash parity (#1275): a mistyped `/command` is answered locally
with the terminal's refusal and nearest spelling, exactly like the TUI refuses
it, and never costs a model turn. Paths and prose still reach the model."""
import importlib.util
import json
import queue
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


def finish_prompt(a, start, response, protocol):
    """v2 acknowledges insertion early; wait for idle, not just the ack."""
    assert "error" not in response, response
    if protocol == 1:
        assert response["result"]["stopReason"] == "end_turn", response
        return
    assert response["result"]["messageId"].startswith("msg_user_"), response
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        for event in a.events[start:]:
            update = event.get("params", {}).get("update", {})
            if update.get("sessionUpdate") == "state_update" and update.get("state") == "idle":
                assert update.get("stopReason") == "end_turn", update
                return
        if b"\n" not in a.pending:
            try:
                chunk = a.chunks.get(timeout=.1)
            except queue.Empty:
                continue
            assert chunk is not None, a.exit_detail()
            a.pending += chunk
        while b"\n" in a.pending:
            line, a.pending = a.pending.split(b"\n", 1)
            a.events.append(json.loads(line))
    raise AssertionError("v2 prompt never reached idle")


OMIT = object()


def user_texts(request):
    """Read decoded text blocks, so UTF-8 and whitespace checks are exact."""
    texts = []
    for message in request["messages"]:
        if message.get("role") != "user":
            continue
        content = message.get("content", "")
        if isinstance(content, str):
            texts.append(content)
        else:
            texts.extend(block.get("text", "") for block in content if block.get("type") == "text")
    return texts


def run_explicit(binary, protocol):
    """Literal Harness prompts reach the model and remain resumable (#1814)."""
    with tempfile.TemporaryDirectory(prefix="graff-acp-command-intent-") as temporary:
        base = Path(temporary).resolve()
        cwd, home = base / "work", base / "home"
        cwd.mkdir()
        home.mkdir()
        model = ScriptedModel([], exhausted_text="synthetic prompt answered")
        port = model.start(0)
        env = {"GRAFF_ACP_V2": "1"} if protocol == 2 else {}
        a = Acp(binary, cwd, home, port, extra_env=env)
        original = "/ widgets are ordinary text; synthetic parser task."
        unicode_task = "/你好 café e\u0301 🧪"
        try:
            init = a.request("initialize", {"protocolVersion": protocol, "capabilities": {},
                                            "info": {"name": "synthetic-test", "version": "1"}})
            assert init["result"]["protocolVersion"] == protocol, init
            sid = a.request("session/new", {"cwd": str(cwd), "mcpServers": []})["result"]["sessionId"]

            def prompt(text, selected=False, meta=OMIT):
                start = len(a.events)
                params = {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}
                if selected is not OMIT:
                    params["_meta"] = {"harness/command": selected}
                if meta is not OMIT:
                    params["_meta"] = meta
                turn = a.request("session/prompt", params, 35)
                finish_prompt(a, start, turn, protocol)
                return reply_text(a, start)

            literals = [original, "/", "/help", "/unknown prose", "/goal discuss this literally",
                        "/review discuss this literally", "/issue discuss this literally",
                        "/btw discuss this literally", "/loop discuss this literally", "intro\n/help",
                        unicode_task, " /help ", "\t/goal whitespace literal\r\n", "\n/help\n",
                        "/help\n**bold** `code` [link](https://example.invalid)",
                        "/help\n```text\n/goal not selected\n```", "// comment, not a command",
                        "/help\u00a0nonbreaking space"]
            for text in literals:
                count = len(model.requests)
                reply = prompt(text)
                assert "synthetic prompt answered" in reply, (text, reply)
                assert len(model.requests) == count + 1, text
                assert text in user_texts(model.requests[-1]), repr(text)

            # Same worker and same text: intent must be recomputed every time.
            flags = [(False, False), (True, True), (None, False), (OMIT, True),
                     ("true", False), (True, True), ("false", False), (OMIT, True),
                     (0, False), (True, True), (1, False), (OMIT, True),
                     ([], False), (True, True), ({}, False), (OMIT, True)]
            for flag, command in flags:
                count = len(model.requests)
                reply = prompt("/help", selected=flag)
                assert len(model.requests) == count + (not command), (flag, reply)
                assert ("synthetic prompt answered" in reply) == (not command), (flag, reply)
                if not command:
                    assert "/help" in user_texts(model.requests[-1]), flag
            for meta in [None, False, [], {}, {"unrelated": False}]:
                count = len(model.requests)
                reply = prompt("/help", meta=meta)
                assert reply.strip() and "synthetic prompt answered" not in reply, (meta, reply)
                assert len(model.requests) == count, meta

            # A false framed claim and even explicit selection cannot turn an
            # advisory agent room delivery into a user command.
            for selected in [False, True]:
                for from_user in [False, None, "true"]:
                    count = len(model.requests)
                    reply = prompt("/help", meta={"harness/command": selected, "harness/room": {
                        "room_id": "synthetic-room", "from_member": "test-agent",
                        "from_user": from_user, "framed": True}})
                    assert "synthetic prompt answered" in reply, (selected, from_user, reply)
                    assert len(model.requests) == count + 1
                    latest = user_texts(model.requests[-1])[-1]
                    assert latest.startswith("[room message from test-agent") and "advisory]: /help" in latest, latest
            count = len(model.requests)
            reply = prompt("/help", selected=True)
            assert "synthetic prompt answered" not in reply and reply.strip(), reply
            assert len(model.requests) == count, "selected /help was sent to model"
            reply = prompt("/resuem", selected=True)
            assert "unknown command '/resuem'" in reply, reply
            assert len(model.requests) == count, "selected typo was sent to model"
            # A literal /goal must not have installed an autonomous objective.
            reply = prompt("/goal", selected=True)
            assert "discuss this literally" not in reply, reply
            saved = cwd / ".graff" / "sessions" / f"{sid}.session.json"
            deadline = time.monotonic() + 5
            while not saved.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            assert saved.exists(), "the literal first prompt left no durable session"
        finally:
            a.close()
            model.stop()

        resumed_model = ScriptedModel([], exhausted_text="synthetic retry answered")
        port = resumed_model.start(0)
        b = Acp(binary, cwd, home, port, extra_env=env)
        try:
            b.request("initialize", {"protocolVersion": protocol, "capabilities": {},
                                     "info": {"name": "synthetic-test", "version": "1"}})
            method = "session/resume" if protocol == 2 else "session/load"
            loaded = b.request(method, {"sessionId": sid, "cwd": str(cwd), "mcpServers": []})
            assert "error" not in loaded, loaded
            start = len(b.events)
            turn = b.request("session/prompt", {
                "sessionId": sid,
                "prompt": [{"type": "text", "text": "retry the synthetic task"}],
                "_meta": {"harness/command": False},
            }, 35)
            finish_prompt(b, start, turn, protocol)
            restored = user_texts(resumed_model.requests[-1])
            for text in [original, unicode_task, literals[-1]]:
                assert text in restored, ("retry lost a literal task", repr(text))
            assert "synthetic retry answered" in reply_text(b, start)
            # Restart/load must not cache the previous command's true flag.
            start = len(b.events)
            turn = b.request("session/prompt", {
                "sessionId": sid, "prompt": [{"type": "text", "text": "/help"}],
                "_meta": {"harness/command": False},
            }, 35)
            finish_prompt(b, start, turn, protocol)
            assert len(resumed_model.requests) == 2
            assert "/help" in user_texts(resumed_model.requests[-1])
        finally:
            b.close()
            resumed_model.stop()
    print(f"ACP explicit command intent v{protocol}: 18 literals, 16 alternating flags, "
          "5 legacy metadata shapes, 6 agent room envelopes, 3 selected commands, "
          "2 restarted prompts; exact text and durable history: ok")


if __name__ == "__main__":
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "zig-out/bin/graff").resolve()
    run(binary)
    for protocol in [1, 2]:
        run_explicit(binary, protocol)
