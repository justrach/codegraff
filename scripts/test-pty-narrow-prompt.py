#!/usr/bin/env python3
"""Real-PTY test for the width-aware interactive prompt/status line (#209).

Before the fix, `Agent.prompt` emitted the full model/effort/provider/cwd/context
status line with no width budget, so a narrow terminal pane soft-wrapped it mid-
badge (e.g. splitting `codex`) and left the cursor visually inside a label. The
fix budgets each segment against `termCols()`: the model and the badges that
disambiguate the cursor come first, and cwd/context/cache/cost are dropped when
they no longer fit, so the rendered line never exceeds the pane width and no
badge is split at the edge.

This drives a real terminal at several widths and asserts:
  * narrow pane  -> the prompt line fits the pane, its badges stay whole, and
    low-priority metadata (cwd) is dropped;
  * wide pane    -> the same launch shows the full metadata (cwd), proving the
    narrow layout is genuine width budgeting and not an unconditional strip.

Rendered (not raw) so the check is independent of the terminal's newline
translation. `-`/`>`-style separators are single display columns and the cwd is
dropped in the narrow case, so len() of the rendered line equals its display
width here.
"""

import os
import sys
import tempfile

from pty_harness import PtySession, terminal_text

_arg = sys.argv[1] if len(sys.argv) > 1 else "graff"
GRAFF = os.path.abspath(_arg) if os.sep in _arg else _arg

MODEL = "deepseek-v4-pro"  # local-only model: no backend, deterministic prompt


def prompt_line(cols: int) -> str:
    """Launch graff in a `cols`-wide pane and return the rendered prompt line."""
    with tempfile.TemporaryDirectory(prefix="graff-pty-narrow-") as tmp:
        env = {
            "HOME": tmp,
            "CODEGRAFF_API_KEY": "local-pty-test",
            "GRAFF_FLEET": "off",
            "GRAFF_NO_TELEMETRY": "1",
        }
        with PtySession(
            GRAFF,
            ["--model", MODEL, "--no-telemetry"],
            cwd=tmp,
            env=env,
            unset_env=("CODEX_HOME", "NO_COLOR"),
            timeout=15.0,
            rows=12,
            cols=cols,
        ) as session:
            session.wait_for_literal("] ›")
            session.pump_for(0.3)  # let the final prompt redraw settle
            rendered = terminal_text(bytes(session.raw))
            # The live prompt is the last line carrying the input marker.
            candidates = [ln for ln in rendered.split("\n") if "] ›" in ln]
            if not candidates:
                raise AssertionError(f"never saw a prompt line:\n{rendered!r}")
            line = candidates[-1]

            session.send_key("ctrl-d")
            result = session.read_until_exit(5.0)
            if result.timed_out or result.exit_code != 0:
                raise SystemExit(
                    f"REPL did not exit cleanly: exit={result.exit_code} "
                    f"timed_out={result.timed_out}"
                )
            return line


def main() -> None:
    narrow_cols = 28  # the width from the issue's tmux repro
    narrow = prompt_line(narrow_cols)

    # 1. The line must fit the pane: an overflow is exactly the soft-wrap that
    #    split badges in the report.
    if len(narrow) > narrow_cols:
        raise AssertionError(
            f"prompt line overflows a {narrow_cols}-col pane (would soft-wrap "
            f"mid-badge, #209): width={len(narrow)} line={narrow!r}"
        )

    # 2. It must still end on a complete frame (never a badge sliced by the edge).
    if not narrow.rstrip().endswith("] ›"):
        raise AssertionError(f"prompt frame is not intact in narrow pane: {narrow!r}")

    # 3. The model badge is mandatory and must appear whole, not truncated.
    if MODEL not in narrow:
        raise AssertionError(f"model badge missing/split in narrow pane: {narrow!r}")

    # 4. Low-priority metadata (cwd) must be the thing that gives way.
    if "cwd" in narrow:
        raise AssertionError(
            f"cwd should be dropped in a {narrow_cols}-col pane: {narrow!r}"
        )

    # 5. A wide pane keeps the full metadata, proving the narrow layout is real
    #    width budgeting and not an unconditional strip. 220 comfortably fits the
    #    model/effort/provider badges plus the temp-dir cwd path at any width.
    wide_cols = 220
    wide = prompt_line(wide_cols)
    if len(wide) > wide_cols:
        raise AssertionError(f"prompt line overflows a {wide_cols}-col pane: {wide!r}")
    if "cwd" not in wide:
        raise AssertionError(f"wide pane should show cwd metadata: {wide!r}")
    if len(wide) <= len(narrow):
        raise AssertionError(
            "prompt line did not adapt to width: "
            f"narrow({narrow_cols})={narrow!r} wide({wide_cols})={wide!r}"
        )

    print("ok    PTY width-aware prompt: no mid-badge wrap in a narrow pane (#209)")


if __name__ == "__main__":
    main()
