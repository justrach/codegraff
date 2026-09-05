#!/usr/bin/env python3
"""Render the real streaming Markdown fixture in a PTY and verify its UI."""

import os
import sys
import tempfile

from pty_harness import run_to_exit


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
# Headings were coral; the palette alignment moved them to the emerald accent
# (ansi.zig style.accent — coral read as error red).
ACCENT = b"\x1b[38;2;5;150;105m"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-md-pty-") as tmp:
        base_env = {
            "HOME": tmp,
            "LMSTUDIO_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }
        color_result = run_to_exit(
            GRAFF,
            ["--selftest-markdown", "--no-telemetry"],
            cwd=tmp,
            env=base_env,
            unset_env=("CODEX_HOME", "NO_COLOR"),
            rows=30,
            cols=100,
            timeout=15.0,
        )
        plain_result = run_to_exit(
            GRAFF,
            ["--selftest-markdown", "--no-telemetry"],
            cwd=tmp,
            env=base_env,
            unset_env=("CODEX_HOME",),
            color=False,
            rows=30,
            cols=100,
            timeout=15.0,
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
        "• Wrapped: https://example.test/a https://example.test/b",
        "• Wrapped: https://example.test/c https://example.test/d",
        "• Wrapped: https://example.test/e https://example.test/f",
        "• URL data: https://example.test/glob/** https://example.test/path/__",
        "• URL data: https://example.test/path/~~ https://example.test/a**b",
        "• Link: https://github.com/justrach/codegraff/issues/728",
    )
    for mode, result in (("color", color_result), ("no-color", plain_result)):
        if result.timed_out or result.exit_code != 0:
            raise SystemExit(
                f"Markdown {mode} self-test failed: exit={result.exit_code} "
                f"timed_out={result.timed_out}"
            )
        missing = [line for line in expected if line not in result.text]
        if missing:
            raise SystemExit(
                f"Markdown {mode} render missing {missing!r}\n--- transcript ---\n{result.text}"
            )
        link_line = next(
            (line for line in result.text.splitlines() if "https://github.com/" in line),
            None,
        )
        if link_line != expected[-1]:
            raise SystemExit(
                f"Markdown {mode} link line is not exact: {link_line!r}"
            )
    if b"\x1b[" in plain_result.raw:
        raise SystemExit("Markdown no-color render unexpectedly contains ANSI")
    for ansi in (ACCENT, b"\x1b[33m", b"\x1b[32m"):
        if ansi not in color_result.raw:
            raise SystemExit(f"Markdown render missing ANSI style {ansi!r}")
    print("ok    PTY Markdown color/no-color links, blocks, inline styles, and ANSI")


if __name__ == "__main__":
    main()
