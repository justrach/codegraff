#!/usr/bin/env python3
"""Smoke the run-wide budget's root-priority behavior at a one-call ceiling."""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
ROOT_REPLY = "RUN_BUDGET_ROOT_OK"


def main() -> None:
    def events(request):
        result = turn_events(f"resp_budget_{request.ordinal}")
        result[0]["item"]["content"][0]["text"] = ROOT_REPLY
        return result

    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-run-budget-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "run-budget-mock",
                            "account_id": "acct-run-budget",
                        }
                    },
                    fh,
                )
            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"ai_title": True, "skills": {"codedbpro": False}}, fh)

            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
                # The explicit CLI ceiling below must win over this default.
                "GRAFF_MAX_MODEL_CALLS": "0",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--max-model-calls", "1", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=10.0,
            ) as session:
                session.wait_for_literal("] ›")
                cursor = len(session.raw)
                session.send_line("answer even though AI titles are enabled")
                session.wait_for_literal(ROOT_REPLY, start=cursor)
                session.wait_for_literal("] ›", start=cursor)
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(
                        f"session exit={result.exit_code} timed_out={result.timed_out}"
                    )
    finally:
        mock.stop()

    requests = mock.recorded_requests()
    if len(requests) != 1:
        raise AssertionError(f"one-call ceiling admitted {len(requests)} requests")
    if "You summarize what a coding session is about" in requests[0].body.get(
        "instructions", ""
    ):
        raise AssertionError("cosmetic title consumed the root's final call")
    print("ok    one-call run budget reserved its final slot for the root answer")


if __name__ == "__main__":
    main()
