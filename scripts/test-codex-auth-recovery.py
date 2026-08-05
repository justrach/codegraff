#!/usr/bin/env python3
"""#402 end-to-end: an expired ChatGPT token is recovered mid-turn, and the
RETRIED request carries the new bearer.

Driven through a real graff process on a PTY, against the codex mock:

  1. ``$CODEX_HOME/auth.json`` holds an expired access token; the session starts
     on it, and every request carries it as ``Authorization: Bearer …``.
  2. Request 1 gets the ChatGPT backend's 401 body verbatim. While serving it,
     the mock rewrites ``$CODEX_HOME/auth.json`` — standing in for the ``/login``
     (or a second graff, or the real ``codex`` CLI) that re-authenticates while
     this session is live.
  3. graff must adopt that credential without a restart and resend the turn.

Asserted on the wire: a second request exists, it carries the NEW bearer and the
new chatgpt-account-id, and the session prints the reply. Before #402 the turn
died on the 401 body and every later turn re-fired the same expired token, which
is exactly what the issue reports.

$CODEX_HOME deliberately is NOT ``$HOME/.codex``: the credential the recovery
reads has to be the one the login flows write, and this scenario only passes when
both resolve to the same file.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

from codex_ws_mock import CodexMock, RecordedRequest
from pty_harness import PtySession

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

FINAL_REPLY = "AUTH_RECOVERY_OK"
EXPIRED_TOKEN = "tok-expired-402"
FRESH_TOKEN = "tok-fresh-402"
EXPIRED_ACCOUNT = "acct-402"
EXPIRED_BODY = json.dumps(
    {
        "error": {
            "message": "Provided authentication token is expired. Please re-authenticate.",
            "type": "unauthorized",
        }
    }
).encode("utf-8")


def write_auth(codex_home: str, token: str) -> None:
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump(
            {
                "auth_mode": "chatgpt",
                "tokens": {
                    "access_token": token,
                    "refresh_token": "",  # no grant to spend: STEP 1 adoption only, no network
                    "account_id": EXPIRED_ACCOUNT,
                },
            },
            fh,
        )


def unauthorized() -> bytes:
    return (
        b"HTTP/1.1 401 Unauthorized\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(EXPIRED_BODY)).encode("ascii") + b"\r\n"
        b"Connection: close\r\n\r\n" + EXPIRED_BODY
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-codex-auth-") as tmp:
        codex_home = os.path.join(tmp, "codex-home")
        os.makedirs(codex_home)
        write_auth(codex_home, EXPIRED_TOKEN)

        def raw(request: RecordedRequest) -> bytes | None:
            if request.ordinal != 1:
                return None
            # The user re-authenticates while the turn is in flight. graff has to
            # notice without being restarted.
            write_auth(codex_home, FRESH_TOKEN)
            return unauthorized()

        def events(request: RecordedRequest) -> list[dict]:
            return [
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "message",
                        "id": "msg_auth_ok",
                        "status": "completed",
                        "role": "assistant",
                        "content": [
                            {"type": "output_text", "text": FINAL_REPLY, "annotations": []}
                        ],
                    },
                },
                {
                    "type": "response.completed",
                    "response": {
                        "id": "resp_auth_ok",
                        "usage": {
                            "input_tokens": 100,
                            "input_tokens_details": {"cached_tokens": 0},
                            "output_tokens": 10,
                            "total_tokens": 110,
                        },
                    },
                },
            ]

        mock = CodexMock(events_for_request=events, raw_for_request=raw)
        port = mock.start()
        try:
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
                if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR")
                and name not in env
            )
            with PtySession(
                GRAFF,
                ["--model", "codex", "--no-telemetry"],
                cwd=tmp,
                env=env,
                unset_env=ambient,
                timeout=20.0,
            ) as session:
                session.wait_for_literal("] ›")
                cursor = len(session.raw)
                session.send_line("say hello")
                session.wait_for_literal(FINAL_REPLY, start=cursor)
                session.wait_for_literal("] ›", start=cursor)
                session.send_key("ctrl-d")
                result = session.read_until_exit(5.0)
                if result.timed_out or result.exit_code != 0:
                    raise AssertionError(
                        f"session exit={result.exit_code} timed_out={result.timed_out}"
                    )

            requests = mock.recorded_requests()
            if len(requests) < 2:
                raise AssertionError(
                    f"the 401 was terminal — no retry was sent: {[r.ordinal for r in requests]!r}"
                )
            first = requests[0].headers.get("authorization", "")
            if first != f"Bearer {EXPIRED_TOKEN}":
                raise AssertionError(f"first attempt did not use the stored token: {first!r}")
            retried = requests[1].headers.get("authorization", "")
            if retried != f"Bearer {FRESH_TOKEN}":
                raise AssertionError(
                    f"the retry did not carry the refreshed bearer: {retried!r}"
                )
            account = requests[1].headers.get("chatgpt-account-id", "")
            if account != EXPIRED_ACCOUNT:
                raise AssertionError(f"account header lost on the retry: {account!r}")
            # The adopted credential must also be the one every LATER request uses,
            # not just this one retry.
            for request in requests[1:]:
                token = request.headers.get("authorization", "")
                if token != f"Bearer {FRESH_TOKEN}":
                    raise AssertionError(
                        f"request {request.ordinal} fell back to a stale token: {token!r}"
                    )
        finally:
            mock.stop()

    print("ok    an expired codex token is adopted mid-turn and the retry carries it")


if __name__ == "__main__":
    main()
