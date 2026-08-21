#!/usr/bin/env python3
"""Real-PTY: /debug and /usage are the live HUD, not a dump toggle or char-count view."""

import os
import sys
import tempfile

from pty_harness import PtySession, terminal_text


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-pty-obs-") as tmp:
        env = {
            "HOME": tmp,
            "CODEGRAFF_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }
        with PtySession(
            GRAFF,
            ["--model", "deepseek-v4-pro", "--no-telemetry"],
            cwd=tmp,
            env=env,
            unset_env=("CODEX_HOME", "NO_COLOR"),
            timeout=15.0,
            cols=240,
        ) as session:
            session.wait_for_prompt()

            cursor = len(session.raw)
            session.send_line("/debug")
            session.wait_for_literal("observability", start=cursor)
            session.wait_for_literal("content-free", start=cursor)
            session.wait_for_literal("turns", start=cursor)
            debug = terminal_text(bytes(session.raw[cursor:]))
            if "offline" in debug:
                raise AssertionError(f"/debug was the offline fallback:\n{debug}")
            if "chars sent" in debug:
                raise AssertionError(f"/debug was a char-count view:\n{debug}")
            if "raw stream" in debug or "GRAFF_REPL_DEBUG" in debug:
                raise AssertionError(f"/debug was the chat-repl dump toggle:\n{debug}")

            cursor = len(session.raw)
            session.send_line("/usage")
            session.wait_for_literal("no API calls yet this session", start=cursor)
            usage = terminal_text(bytes(session.raw[cursor:]))
            if "chars sent" in usage:
                raise AssertionError(f"/usage was a char-count view:\n{usage}")

            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} "
                    f"timed_out={result.timed_out}"
                )
    print("ok    PTY /debug HUD and /usage (no char-count, not offline)")


if __name__ == "__main__":
    main()
