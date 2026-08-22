#!/usr/bin/env python3
"""Deterministic real-PTY smoke test for interactive REPL state/redraws."""

import os
import sys
import tempfile

from pty_harness import PtySession, terminal_text


_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg
# The effort/ultracode badges and the picker selection moved from coral to the
# emerald accent when the palette aligned to the site (coral is reserved for
# errors) — ansi.zig style.accent / pickers.zig.
ACCENT = b"\x1b[38;2;5;150;105m"
RESET = b"\x1b[0m"


def main() -> None:
    assert terminal_text(b"prompt\r\x1b[2Kdone") == "done"
    assert terminal_text(b"abc\x1b[2DXY") == "aXY"
    with tempfile.TemporaryDirectory(prefix="graff-pty-") as tmp:
        env = {
            "HOME": tmp,
            "CODEGRAFF_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }
        # A wide pane so the full status line (all mode badges + the deep temp
        # cwd) fits without the width budgeting (#209) dropping cwd; narrow-
        # width layout is covered by the pure-Zig prompt-budget tests in
        # agent_prompt.zig.
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

            def command(
                line: str,
                output: str,
                prompt: str,
                color_bytes: bytes | None,
            ) -> None:
                cursor = len(session.raw)
                session.send_line(line)
                session.wait_for_literal(output, start=cursor)
                session.wait_for_literal(prompt, start=cursor)
                if color_bytes is not None and color_bytes not in bytes(session.raw[cursor:]):
                    raise AssertionError(f"missing colored badge {color_bytes!r} after {line}")

            # Dim meter above a bare › (ADR 0016): model · effort · ~/cwd ·
            # badges. Provider and privacy left the line; ctx/session follow.
            # Cwd returned as a `~/folder` segment (98958fc) — use the temp
            # dir's basename so the literals stay deterministic.
            base = f"deepseek-v4-pro · Extra high · ~/{os.path.basename(tmp)}"
            command(
                "/effort xhigh",
                "reasoning effort: Extra high",
                base,
                None,  # effort sits on the dim meter line, not an accent badge
            )
            command(
                "/model definitely-not-a-model",
                "unknown model 'definitely-not-a-model'",
                base,
                None,
            )
            cursor = len(session.raw)
            session.send_line("/help")
            session.wait_for_literal("/models [health]", start=cursor)
            session.wait_for_literal("/fallback [allow|remove|off]", start=cursor)
            session.wait_for_literal("/login [codegraff|codex|kimi]", start=cursor)
            session.wait_for_literal(base, start=cursor)
            session.wait_for_prompt(start=cursor)
            cursor = len(session.raw)
            session.send_line("/models health")
            session.wait_for_literal("active: deepseek-v4-pro via codegraff", start=cursor)
            session.wait_for_literal("Codex catalog:", start=cursor)
            session.wait_for_literal(
                "Codex transport: WebSocket primary with automatic SSE fallback",
                start=cursor,
            )
            session.wait_for(r"✓\s+codegraff\s+environment", start=cursor)
            session.wait_for(r"·\s+codex\s+missing", start=cursor)
            session.wait_for_literal(base, start=cursor)
            session.wait_for_prompt(start=cursor)
            if b"local-pty-test" in bytes(session.raw[cursor:]):
                raise AssertionError("/models health exposed a credential value")
            command(
                "/plan",
                "plan mode on",
                f"{base} · Plan",
                None,
            )
            command(
                "/strict",
                "strict mode ON",
                f"{base} · Plan · Strict",
                None,
            )
            command(
                "/ultracode on",
                "ultracode mode: on",
                f"{base} · Plan · Strict · Ultracode",
                None,
            )
            command(
                "/yolo",
                "yolo mode ON",
                f"{base} · Plan · Strict · Ultracode",
                None,
            )
            if b"\x1b[31mYOLO\x1b[0m" in bytes(session.raw):
                raise AssertionError("YOLO should be reported outside the compact prompt")
            cursor = len(session.raw)
            session.send_line("/key no-such-provider supersecret")
            session.wait_for_literal("unknown provider 'no-such-provider'", start=cursor)
            session.wait_for_prompt(start=cursor)
            if b"supersecret" in bytes(session.raw[cursor:]):
                raise AssertionError("/key secret was echoed to the terminal")
            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} timed_out={result.timed_out}"
                )
        history = os.path.join(tmp, ".simple-harness-history")
        if os.path.exists(history) and "supersecret" in open(history, encoding="utf-8").read():
            raise AssertionError("/key secret was persisted in REPL history")

        # A short/narrow PTY used to overflow because both pickers always drew
        # 18 rows with fixed 26/11-column cells. The model picker should fit in
        # 12 rows and initially highlight the active model; the settings picker
        # should retain its persisted current value too.
        with PtySession(
            GRAFF,
            ["--model", "deepseek-v4-pro", "--no-telemetry"],
            cwd=tmp,
            env=env,
            unset_env=("CODEX_HOME", "NO_COLOR"),
            timeout=15.0,
            rows=12,
            cols=44,
        ) as session:
            session.wait_for_prompt()
            cursor = len(session.raw)
            session.send_line("/model")
            session.wait_for_literal("CTX/KEY", start=cursor)
            session.pump_for(0.1)
            paint = bytes(session.raw[cursor:]).rsplit(b"\x1b[2J\x1b[H", 1)[-1]
            if paint.count(b"\n") != 11:
                raise AssertionError("model picker exceeded its 12-row terminal budget")
            if ACCENT + b"\xe2\x80\xba deepseek-v4-pro" not in paint:
                raise AssertionError("model picker did not initially select the active model")
            session.send_key("ctrl-c")
            session.wait_for_prompt(start=cursor)

            cursor = len(session.raw)
            session.send_line("/effort")
            session.wait_for_literal("Reasoning level for", start=cursor)
            session.wait_for_literal("Ultra", start=cursor)
            session.pump_for(0.1)
            paint = bytes(session.raw[cursor:]).rsplit(b"\x1b[2J\x1b[H", 1)[-1]
            if ACCENT + b"\xe2\x80\xba Extra high" not in paint:
                raise AssertionError("reasoning picker did not initially select the current level")
            session.send_key("ctrl-c")
            session.wait_for_prompt(start=cursor)
            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"narrow REPL did not exit cleanly: exit={result.exit_code} timed_out={result.timed_out}"
                )
    print("ok    PTY REPL commands, colored mode badges, redraws, and clean exit")


if __name__ == "__main__":
    main()
