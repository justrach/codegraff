#!/usr/bin/env python3
"""Reproduce #480 with concurrent interactive Codex WebSocket tool loops."""

import json
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor

from codex_ws_mock import CodexMock
import codex_ws_test as scenario


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-pty-codex-concurrent-") as tmp:
        codex_home = os.path.join(tmp, "codex-home")
        os.makedirs(codex_home)
        with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "tokens": {
                        "access_token": "pty-concurrent-mock",
                        "account_id": "acct-pty-concurrent",
                    }
                },
                fh,
            )

        mock = CodexMock(events_for_request=scenario.concurrent_tool_events)
        port = mock.start()
        try:
            def run_session(index: int) -> None:
                session_dir = os.path.join(tmp, f"session-{index}")
                os.makedirs(os.path.join(session_dir, ".harness"))
                with open(
                    os.path.join(session_dir, ".harness", "settings.json"),
                    "w",
                    encoding="utf-8",
                ) as fh:
                    # Keep the detached first-turn title enabled: it overlaps the
                    # root WS turn in the interactive-only shape from #480.
                    json.dump({"ai_title": True, "session_recap": False}, fh)
                env = {
                    "HOME": session_dir,
                    "CODEX_HOME": codex_home,
                    "CODEGRAFF_API_KEY": "local-pty-test",
                    "GRAFF_FLEET": "off",
                    "GRAFF_NO_TELEMETRY": "1",
                    "GRAFF_CODEX_URL": (
                        f"http://127.0.0.1:{port}/backend-api/codex/responses"
                    ),
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
                with scenario.PtySession(
                    scenario.GRAFF,
                    ["--model", "codex", "--no-telemetry"],
                    cwd=session_dir,
                    env=env,
                    unset_env=ambient,
                    timeout=20.0,
                ) as session:
                    session.wait_for_prompt()
                    cursor = len(session.raw)
                    session.send_line(f"concurrent feature task {index}")
                    session.wait_for_literal(scenario.CONCURRENT_FINAL, start=cursor)
                    session.wait_for_prompt(start=cursor)
                    session.send_key("ctrl-d")
                    result = session.read_until_exit(5.0)
                    if result.timed_out or result.exit_code != 0:
                        raise AssertionError(
                            f"session {index} failed to exit: "
                            f"exit={result.exit_code} timed_out={result.timed_out}"
                        )

            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(run_session, index) for index in range(4)]
                for future in futures:
                    future.result(timeout=30.0)

            if mock.ws_connections != 4 or mock.ws_turns != 8 or mock.sse_turns != 4:
                raise AssertionError(
                    "concurrent WS tool-loop counts changed: "
                    f"connections={mock.ws_connections} ws={mock.ws_turns} "
                    f"title_sse={mock.sse_turns}"
                )
        finally:
            mock.stop()

    print(
        "ok    four concurrent interactive WS sessions: detached title + "
        "native tool loop -> answer -> prompt, without a post-response hang"
    )


if __name__ == "__main__":
    main()
