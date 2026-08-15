#!/usr/bin/env python3
"""Regression for #478: ask_user must not wedge after piped stdin reaches EOF."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest, turn_events


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
FINAL_REPLY = "ASK_EOF_DONE"


def events(request: RecordedRequest) -> list[dict]:
    if request.ordinal == 1:
        return [
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "function_call",
                    "id": "fc_ask_eof",
                    "call_id": "call_ask_eof",
                    "name": "ask_user",
                    "arguments": json.dumps({"question": "Need input?"}),
                    "status": "completed",
                },
            },
            turn_events("resp_ask_eof_1")[1],
        ]

    response = turn_events("resp_ask_eof_2")
    response[0]["item"]["content"][0]["text"] = FINAL_REPLY
    return response


def main() -> None:
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-ask-eof-") as tmp:
            codex_home = os.path.join(tmp, "codex-home")
            os.makedirs(codex_home)
            with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "tokens": {
                            "access_token": "ask-eof-mock",
                            "account_id": "acct-ask-eof",
                        }
                    },
                    fh,
                )

            harness_dir = os.path.join(tmp, ".harness")
            os.makedirs(harness_dir)
            with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
                json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)

            env = os.environ.copy()
            for name in tuple(env):
                if name.startswith("GRAFF_") or name.startswith("CODEX_"):
                    env.pop(name)
            env.update(
                {
                    "HOME": tmp,
                    "CODEX_HOME": codex_home,
                    "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
                    "GRAFF_CODEX_WS": "off",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                    "NO_COLOR": "1",
                }
            )

            proc = subprocess.run(
                [GRAFF, "--model", "codex", "--no-telemetry"],
                cwd=tmp,
                env=env,
                input="ask me a question using ask_user\n",
                text=True,
                capture_output=True,
                timeout=15,
                check=False,
            )
            if proc.returncode != 0:
                raise AssertionError(
                    f"graff exited {proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
                )
            if FINAL_REPLY not in proc.stdout:
                raise AssertionError(f"missing final reply in stdout: {proc.stdout!r}")

            requests = mock.recorded_requests()
            root_requests = [request for request in requests if "tools" in request.body]
            if len(root_requests) != 2:
                raise AssertionError(
                    f"expected two root model calls, got {len(root_requests)}: "
                    f"{[request.body for request in requests]!r}\nstdout={proc.stdout!r}"
                )
            followup = json.dumps(root_requests[1].body)
            if "function_call_output" not in followup:
                raise AssertionError(f"missing ask_user tool result: {followup}")
            if "user ended input without answering" not in followup:
                raise AssertionError(f"EOF result was not explicit: {followup}")
    finally:
        mock.stop()


if __name__ == "__main__":
    main()
