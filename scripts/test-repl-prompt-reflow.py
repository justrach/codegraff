#!/usr/bin/env python3
"""Real-PTY guard for reflowable submitted prompts in the line REPL.

The editor may use CRLF while positioning a live multi-row draft, but Enter
must erase that block and emit the logical prompt contiguously. A terminal can
then treat width-only wraps as soft rows and reflow them after a resize.
"""

import fcntl
import os
import struct
import sys
import tempfile
import termios

from pty_harness import PtySession


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="graff-repl-reflow-") as tmp:
        harness = os.path.join(tmp, ".harness")
        os.makedirs(harness)
        with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
            fh.write('{"ai_title":false,"skills":{"codedbpro":false}}')
        empty_mcp = os.path.join(tmp, "empty-mcp.json")
        with open(empty_mcp, "w", encoding="utf-8") as fh:
            fh.write('{"mcpServers":{}}')
        env = {
            "HOME": tmp,
            "CODEGRAFF_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_LEARN_AUTO": "off",
            "GRAFF_MCP_CONFIG": empty_mcp,
            "GRAFF_NO_TELEMETRY": "1",
        }
        with PtySession(
            GRAFF,
            ["--model", "deepseek-v4-pro", "--no-telemetry"],
            cwd=tmp,
            env=env,
            unset_env=("CODEX_HOME", "NO_COLOR"),
            color=True,
            timeout=15.0,
            rows=30,
            cols=100,
        ) as session:
            session.wait_for_prompt()
            fcntl.ioctl(
                session.fd,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 30, 28, 0, 0),
            )
            line = (
                "/goal submitted prompts use terminal autowrap so completed "
                "text can reflow when the pane becomes wider"
            )
            cursor = len(session.raw)
            session.send_line(line)
            end = session.wait_for_literal("Goal set:", start=cursor)
            window = bytes(session.raw[cursor:end])
            if line.encode() not in window:
                raise AssertionError(
                    "submitted prompt was never emitted as one logical line; "
                    "editor-width CRLF boundaries would remain hard scrollback"
                )

            fcntl.ioctl(
                session.fd,
                termios.TIOCSWINSZ,
                struct.pack("HHHH", 30, 100, 0, 0),
            )
            session.wait_for_prompt(start=end)
            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} "
                    f"timed_out={result.timed_out}"
                )
    print("ok    line-REPL submitted prompts keep soft wraps reflowable")


if __name__ == "__main__":
    main()
