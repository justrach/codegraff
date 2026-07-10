#!/usr/bin/env python3
"""Render the real streaming Markdown fixture in a PTY and verify its UI."""

import os
import sys
import tempfile

from pty_harness import run_to_exit


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-md-pty-") as tmp:
        result = run_to_exit(
            GRAFF,
            ["--selftest-markdown", "--no-telemetry"],
            cwd=tmp,
            env={
                "HOME": tmp,
                "LMSTUDIO_API_KEY": "local-pty-test",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_TELEMETRY": "1",
            },
            unset_env=("CODEX_HOME", "NO_COLOR"),
            rows=30,
            cols=100,
            timeout=15.0,
        )
    if result.timed_out or result.exit_code != 0:
        raise SystemExit(
            f"Markdown self-test failed: exit={result.exit_code} timed_out={result.timed_out}"
        )
    expected = (
        "◆ Gaps",
        "• No bot-specific route tests exist.",
        "• Pin install.sh and verify its checksum.",
        "◆ Recommended implementation order",
        "1. Immediately: require collaborator permission.",
        "2) Next: deduplicate X-GitHub-Delivery.",
        "☐ Add a Daytona credential preflight.",
        "☑ Sanitize public errors.",
        "  ◦ Preserve private incident detail.",
        "│ Public errors must never expose secrets.",
    )
    missing = [line for line in expected if line not in result.text]
    if missing:
        raise SystemExit(f"Markdown render missing {missing!r}\n--- transcript ---\n{result.text}")
    for ansi in (b"\x1b[36m", b"\x1b[33m", b"\x1b[32m"):
        if ansi not in result.raw:
            raise SystemExit(f"Markdown render missing ANSI style {ansi!r}")
    print("ok    PTY Markdown headings, lists, tasks, quotes, inline styles, and ANSI")


if __name__ == "__main__":
    main()
