#!/usr/bin/env python3
"""Real-PTY smoke test for the #469 peer-message delivery pipeline.

A device-room broadcast planted while the session sits at the prompt must
render as a [peer message from ...] line during the next turn's first step
boundary. This pins the end-to-end plumbing (chan-all.jsonl -> drainDevice ->
deliverInbound -> session_notice), which no unit test reaches.

It deliberately does NOT assert the blank-line bracket: a rendered PTY
transcript cannot attribute a blank line to the drain (the turn card, tool-row
groups, and stream lead-in all emit their own blanks depending on position),
so that assertion false-passes on pre-fix builds. The bracket is pinned
deterministically by the renderPeerBlock unit test in src/peer_channel.zig.

The injected line rides the device room: from_user + unaddressed is heard by
every session, and the room's fixed name needs no identity hash. The isolated
HOME makes that room private to this test, so nothing here reaches real peer
sessions. The title request is answered by content match — it races the first
turn call, so it must not consume a scripted reply.
"""

import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "eval"))

from mock_model import ScriptedModel  # noqa: E402
from pty_harness import PtySession, terminal_text  # noqa: E402


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

PEER_LINE = "[peer message from session-fake-peer"
TITLE_MARK = "You summarize what a coding session is about"


class TitleAwareModel(ScriptedModel):
    """Script the turn replies; answer title calls out of band so the title
    race can never eat a scripted turn reply."""

    def next_reply(self, body):
        messages = body.get("messages", [])
        if any(TITLE_MARK in str(m.get("content", "")) for m in messages):
            return {"text": "spacing probe session"}
        return super().next_reply(body)


def main() -> None:
    model = TitleAwareModel([{"text": "mock reply"}], exhausted_text="mock reply")
    model.start(1234)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-pty-peer-") as tmp:
            home = os.path.join(tmp, "home")
            repo = os.path.join(tmp, "repo")
            os.makedirs(repo)
            os.system(f"git init -q {repo}")
            env = {
                "HOME": home,
                "CODEGRAFF_API_KEY": "local-pty-test",
                "LMSTUDIO_API_KEY": "local-pty-test",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_NO_SMOLIFY": "1",
            }
            with PtySession(
                GRAFF,
                ["--model", "lmstudio", "--yolo"],
                cwd=repo,
                env=env,
                unset_env=("CODEX_HOME", "NO_COLOR"),
                timeout=25.0,
            ) as session:
                session.wait_for_prompt()

                live = os.path.join(home, ".graff", "live")
                deadline = time.time() + 10
                while not os.path.isdir(live) and time.time() < deadline:
                    time.sleep(0.1)
                assert os.path.isdir(live), "presence registry never appeared"

                cursor = len(session.raw)
                with open(os.path.join(live, "chan-all.jsonl"), "a") as fh:
                    fh.write(json.dumps({
                        "from_pid": 999999, "from_start": 1,
                        "from_session": "session-fake-peer", "from_goal": "",
                        "to": "", "ts_ms": int(time.time() * 1000),
                        "text": "spacing probe", "from_user": True,
                    }) + "\n")
                session.send_line("hi")
                end = session.wait_for_literal("mock reply", start=cursor)
                session.pump_for(0.5)

                rendered = terminal_text(bytes(session.raw[cursor:end]))
                lines = rendered.split("\n")
                idx = next(
                    (i for i, l in enumerate(lines) if PEER_LINE in l), None
                )
                assert idx is not None, (
                    "peer block never rendered\n--- transcript ---\n" + rendered
                )
                print("ok: device-room broadcast renders as a peer line mid-session")
    finally:
        model.stop()


if __name__ == "__main__":
    main()
