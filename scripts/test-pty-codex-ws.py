#!/usr/bin/env python3
"""Deterministic real-PTY test for codex transport: WebSocket primary, forced
SSE fallback, and GRAFF_CODEX_WS=off — each against a local fake backend
(codex_ws_mock) whose ws_turns/sse_turns counters prove which transport
actually served the turn, so a silent fallback cannot fake a pass."""

import json
import os
import sys
import tempfile

from codex_ws_mock import REPLY_TEXT, CodexMock
from pty_harness import PtySession

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

# Mock usage total is 1500; compactTokenCount (src/agent.zig) renders that as
# "1k" (integer division). contextFor("codex","gpt-5.6-sol") = 372_000, so the
# prompt meter is 1500*100/372000 = 0% with compact@ 372000/10*8/1000 = 297k.
METER = "1k/372k ctx (0% · compact@297k)"


def run_scenario(
    label: str,
    tmp: str,
    codex_home: str,
    port: int,
    mock: CodexMock,
    extra_env: dict,
    expect_ws: int,
    expect_sse: int,
    health: str,
) -> None:
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "CODEGRAFF_API_KEY": "local-pty-test",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
    }
    env.update(extra_env)
    # PtySession builds the child env from os.environ.copy(), so ambient
    # transport/credential knobs (an exported GRAFF_CODEX_WS=off, a leftover
    # GRAFF_WS_FORCE_FAIL_ONCE=1, CODEX_DISABLED, ...) would leak into every
    # scenario and flip its transport. Strip all ambient GRAFF_*/CODEX_* the
    # scenario does not set itself; unset_env is applied AFTER env, so keys we
    # set deliberately must be excluded.
    ambient = tuple(
        k
        for k in os.environ
        if (k.startswith("GRAFF_") or k.startswith("CODEX_") or k == "NO_COLOR")
        and k not in env
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
        session.send_line("ping")
        session.wait_for_literal(REPLY_TEXT, start=cursor)
        session.wait_for_literal(METER, start=cursor)
        if mock.ws_turns != expect_ws or mock.sse_turns != expect_sse:
            raise AssertionError(
                f"{label}: transport mismatch — ws_turns={mock.ws_turns} "
                f"sse_turns={mock.sse_turns}, expected ws={expect_ws} sse={expect_sse}"
            )
        cursor = len(session.raw)
        session.send_line("/models health")
        session.wait_for_literal(f"Codex transport: {health}", start=cursor)
        session.wait_for_literal("] ›", start=cursor)
        session.send_key("ctrl-d")
        result = session.read_until_exit(5.0)
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                f"{label}: REPL did not exit cleanly: "
                f"exit={result.exit_code} timed_out={result.timed_out}"
            )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-pty-codex-") as tmp:
        codex_home = os.path.join(tmp, "codex-home")
        os.makedirs(codex_home, exist_ok=True)
        with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {"tokens": {"access_token": "pty-mock-token", "account_id": "acct-pty-mock"}},
                fh,
            )

        # The AI tab-titler (titleTask, src/title.zig) fires one extra quiet SSE
        # turn on the first prompt, which would corrupt the transport counters.
        # Disable it the same way `/title off` does: the persisted setting in
        # the session cwd's .harness/settings.json.
        harness_dir = os.path.join(tmp, ".harness")
        os.makedirs(harness_dir, exist_ok=True)
        with open(os.path.join(harness_dir, "settings.json"), "w", encoding="utf-8") as fh:
            json.dump({"ai_title": False}, fh)

        scenarios = [
            (
                "ws-primary",
                {},
                1,
                0,
                "WebSocket primary with automatic SSE fallback",
                "ok    codex WS primary: mock reply + ctx meter over WebSocket",
            ),
            (
                "ws-forced-fallback",
                {"GRAFF_WS_FORCE_FAIL_ONCE": "1"},
                0,
                1,
                "SSE fallback (WebSocket failed this session)",
                "ok    codex forced WS failure: SSE fallback reply + ctx meter + latched health",
            ),
            (
                "ws-off",
                {"GRAFF_CODEX_WS": "off"},
                0,
                1,
                "SSE forced (GRAFF_CODEX_WS is off)",
                "ok    codex WS disabled: SSE reply + ctx meter + forced-off health",
            ),
        ]
        for label, extra_env, expect_ws, expect_sse, health, ok_line in scenarios:
            mock = CodexMock()
            port = mock.start()
            try:
                run_scenario(
                    label,
                    tmp,
                    codex_home,
                    port,
                    mock,
                    extra_env,
                    expect_ws,
                    expect_sse,
                    health,
                )
            finally:
                mock.stop()
            print(ok_line)


if __name__ == "__main__":
    main()
