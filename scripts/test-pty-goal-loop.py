#!/usr/bin/env python3
"""Real-PTY regression for the /goal autonomous collapse (v0.0.222, #224).

`src/goal_pacing_autonomous_test.zig` pins the PARSE (`autonomousFromLine`),
but src/main.zig returns through session_run.runOneshotPrompt for every -p
or --json path before src/mainloop.zig even exists, so nothing headless can
reach the WIRING: whether typing `/goal <objective>` in the interactive REPL
actually adopts a standing goal AND fires a turn, whether a duration prefix
is stripped before the objective is recorded, and whether the continuation
turn the /loop controller queues really carries the pacing note. This drives
a real PTY against a scripted codex mock and inspects what was SENT, the
only way to prove the seam in mainloop.zig (`goal_pacing.autonomousFromLine`
-> `goal_flow.loopTurnDecision` -> the synthesized continuation line) is
actually wired end to end.

Mock script (by request ordinal, everything else is deterministic given the
fixed input sequence below):
  1  first exchange of the initial "/goal ship the thing" turn -> a real
     tool call (todo_read, read-only: no approval gate to drive in the PTY)
  2  second exchange of that same turn, after the tool result -> a final
     message with no further tool call. tool_calls_this_turn ends at 1, so
     goal_flow.loopTurnDecision authorizes one continuation.
  3  the synthesized continuation turn ("/loop [continuing...]\\n[pace: ...]")
     -> a final message with no tool call, so tool_calls_this_turn is 0 and
     the loop stops `idle` (clean, no 25-iteration runaway).
  4  the "/goal 30m ship the thing" turn -> a final message with no tool
     call, stopping `idle` immediately.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def _tool_call_events(ordinal: int) -> list[dict]:
    """One real (read-only) tool call, so tool_calls_this_turn is nonzero."""
    return [
        {
            "type": "response.output_item.done",
            "item": {
                "type": "function_call",
                "id": f"fc_goal_{ordinal}",
                "call_id": f"call_goal_{ordinal}",
                "name": "todo_read",
                "arguments": "{}",
                "status": "completed",
            },
        },
        turn_events(f"resp_goal_tool_{ordinal}")[1],
    ]


def _final_events(ordinal: int) -> list[dict]:
    """A plain final message with NO tool call: turnStopped == true."""
    events = turn_events(f"resp_goal_{ordinal}")
    events[0]["item"]["content"][0]["text"] = f"GOAL_TURN_{ordinal}_DONE"
    return events


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return _tool_call_events(request.ordinal)
    return _final_events(request.ordinal)


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-goal-loop-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "goal-loop-mock",
                            "account_id": "acct-goal-loop",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                # Cosmetic title/recap calls shift the request ordinals this test
                # scripts against, so disable both for this isolated PTY fixture.
                json.dump(
                    {"ai_title": False, "session_recap": False, "skills": {"codedbpro": False}}, fh
                )

            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",  # SSE only: one request per exchange, no framing to race
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=10.0,
            ) as session:
                session.wait_for_literal("] ›")

                # 1. "/goal ship the thing" adopts a standing goal AND runs a turn
                # immediately: the goal-set line prints, and the loop controller's
                # one authorized continuation (tool_calls_this_turn == 1 on turn 1)
                # fires and then stops idle — proving the WIRING, not just the parse.
                cursor = len(session.raw)
                session.send_line("/goal ship the thing")
                session.wait_for_literal("Goal set: ship the thing", start=cursor)
                session.wait_for_literal("run stopped — idle", start=cursor, timeout=10.0)
                session.wait_for_literal("] ›", start=cursor)

                # 2. "/goal 30m ship the thing" prints the budget line (the arm
                # announcement), and the recorded objective must NOT contain "30m" —
                # goal_pacing.autonomousFromLine strips the duration before rebuilding
                # the /goal command line.
                cursor = len(session.raw)
                session.send_line("/goal 30m ship the thing")
                session.wait_for_literal("/loop budget: 30m", start=cursor)
                session.wait_for_literal("Goal set: ship the thing", start=cursor)
                session.wait_for_literal("run stopped — idle", start=cursor, timeout=10.0)
                session.wait_for_literal("] ›", start=cursor)

                # 4. "/goal status" stays a COMMAND: no turn runs.
                before_status = len(mock.recorded_requests())
                cursor = len(session.raw)
                session.send_line("/goal status")
                session.wait_for_literal("Status: active", start=cursor)
                session.wait_for_literal("] ›", start=cursor)
                if len(mock.recorded_requests()) != before_status:
                    raise AssertionError(
                        "/goal status ran a model turn; it must stay a lifecycle command"
                    )

                # 5. Clean exit.
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(
                        f"session did not exit cleanly: exit={result.exit_code} "
                        f"timed_out={result.timed_out}"
                    )
    finally:
        mock.stop()

    requests = mock.recorded_requests()
    if len(requests) != 4:
        raise AssertionError(f"expected exactly 4 model requests, got {len(requests)}")

    turn1_first = json.dumps(requests[0].body)
    if "ship the thing" not in turn1_first:
        raise AssertionError("the objective never reached the model on the first /goal turn")
    if "standing goal:" not in turn1_first:
        raise AssertionError("the standing-goal steering note was not sent on the /goal turn")

    # 3. The continuation turn (request 3: turn 1's tool call authorized exactly
    # one continuation) carries the pacing line — proof the /loop controller,
    # not just the parser, actually ran.
    continuation = json.dumps(requests[2].body)
    if "continuation" not in continuation or "elapsed" not in continuation:
        raise AssertionError(
            "the continuation turn did not carry goal_pacing.pacingNote "
            f"('continuation'/'elapsed' missing): {continuation[:400]!r}"
        )

    combined = " ".join(json.dumps(r.body) for r in requests)
    if "30m" in combined:
        raise AssertionError("the duration prefix leaked into what was sent to the model")

    print(
        "ok    /goal adopts a standing goal, strips its duration, runs the "
        "controller-authorized continuation with the pacing note, and /goal "
        "status stays a command"
    )


if __name__ == "__main__":
    main()
