#!/usr/bin/env python3
"""Real-PTY test for the blank-line gutter between a submitted prompt and output (#205).

Submitting a line must leave one blank line between the prompt and whatever prints
next, so it is easy to see where the response starts. readline emits a second
newline on Enter for this; here we drive a real terminal and assert the rendered
transcript shows that gutter. Rendered (not raw) so the check is independent of the
terminal's newline translation (ONLCR).
"""

import os
import sys
import tempfile

from pty_harness import PtySession, terminal_text


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-pty-gutter-") as tmp:
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
        ) as session:
            session.wait_for_prompt()

            # A local slash command produces output without touching a backend.
            cursor = len(session.raw)
            session.send_line("/help")
            end = session.wait_for_literal("/models [health]", start=cursor)

            # In the isolated post-submit window the submitted line(s) render first,
            # then the command output; the blank-line gutter (#205) must sit
            # immediately BEFORE the first output line. The number of echoed input
            # lines varies with redraw timing, so anchor on the output, not indices.
            rendered = terminal_text(bytes(session.raw[cursor:end]))
            lines = rendered.split("\n")
            out_idx = next(
                (i for i, ln in enumerate(lines) if ln.startswith("commands (bare")),
                None,
            )
            if out_idx is None:
                raise AssertionError(f"never saw the /help output:\n{rendered!r}")
            if out_idx < 1 or lines[out_idx - 1].strip() != "":
                raise AssertionError(
                    "no blank-line gutter between the submitted prompt and its "
                    f"output (#205); lines={lines[: out_idx + 1]!r}"
                )
            if not any("/help" in ln for ln in lines[:out_idx]):
                raise AssertionError(f"submitted line missing:\n{rendered!r}")

            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} "
                    f"timed_out={result.timed_out}"
                )
    print("ok    PTY prompt/output blank-line gutter (#205)")


if __name__ == "__main__":
    main()
