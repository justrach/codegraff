#!/usr/bin/env python3
"""Real-PTY regression for immediate multiline paste into ask_user."""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest, turn_events
from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return [
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "id": "fc_ask_paste",
                    "call_id": "call_ask_paste",
                    "name": "ask_user",
                    "arguments": json.dumps(
                        {
                            "question": "Paste details",
                            "options": ["one", "two"],
                        }
                    ),
                    "status": "completed",
                },
            },
            turn_events("resp_ask_paste_1")[1],
        ]

    response = turn_events("resp_ask_paste_2")
    response[0]["item"]["content"][0]["text"] = "ASK_PASTE_DONE"
    return response


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-ask-paste-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "ask-paste-mock",
                            "account_id": "acct-ask-paste",
                        }
                    },
                    fh,
                )

            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)

            env = {
                "HOME": tmp,
                "CODEX_HOME": codex_home,
                "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                "GRAFF_CODEX_WS": "off",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            }
            ambient = tuple(
                name
                for name in os.environ
                if (
                    name.startswith("GRAFF_")
                    or name.startswith("CODEX_")
                    or name == "NO_COLOR"
                )
                and name not in env
            )

            with PtySession(
                GRAFF,
                ["--model", "codex", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=15.0,
            ) as session:
                session.wait_for_prompt()
                session.send_line("ask me for details")
                session.wait_for_literal("your answer ›")

                cursor = len(session.raw)
                session.send(b"\x1b[200~first line\nsecond line\x1b[201~")
                session.wait_for_literal(
                    "[Pasted text #1 +2 lines]",
                    start=cursor,
                )
                session.send_key("enter")
                session.wait_for_literal("ASK_PASTE_DONE", start=cursor)

            requests = mock.recorded_requests()
            assert len(requests) == 2, f"expected 2 requests, got {len(requests)}"
            payload = json.dumps(requests[-1].body, ensure_ascii=False)
            assert "first line\\nsecond line" in payload, payload
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
