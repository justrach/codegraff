#!/usr/bin/env python3
"""Every overlay is a bordered panel, docked to the composer, opened at its top.

grok-build renders a modal as a BLOCK with borders on all four sides and the
title inlaid in the top rule (`─ <bold title> ─`, dashes in the border colour),
with the keys on a dim footer row; its minimal-mode list panels dock to the
prompt instead of floating mid-screen. graff's overlays used to be bare text
hanging at the top of the pager with a field of blank rows between the list and
the caret choosing from it, and a title that spent a content row.

This drives the REAL binary on a virtual screen (scripts/ptyharness.py) and
reads back what a terminal would show, at three widths, for four surfaces:

  1. /model    — a windowed list: framed, tallied in the top rule, docked one
                 row above the composer, and honest about the rows it is not
                 showing ("… N below").
  2. /         — the completion menu wears the SAME frame as the palette it
                 mirrors, so one catalogue reached two ways looks like one
                 thing.
  3. /help     — a sheet taller than the screen OPENS AT ITS FIRST ROW (it used
                 to open at its last: the only part you ever saw was the tail of
                 the command list) and pages down to the rest.
  4. composer  — the standing row that claimed "Image in clipboard" on every
                 idle frame is gone, and the paste key lives in the footer hint
                 with the other keys.

Every panel row is checked against the frame width in CELLS, which is the one
thing a raw-byte grep cannot do: a border that measured one column wide would
be chopped by the terminal and slide every row below it.

Usage: python3 scripts/test-tui-overlay-panels.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) when the binary is absent or there is no
pty here.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ptyharness import PtyHarness, PtyTimeout  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
ROWS = 30
WIDTHS = (60, 80, 120)

TL, TR, BL, BR = "╭", "╮", "╰", "╯"
WALL = "│"


def workspace(tmp: str) -> dict:
    empty = os.path.join(tmp, "empty-mcp.json")
    with open(empty, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness, exist_ok=True)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    return {
        "HOME": tmp,
        "GRAFF_MCP_CONFIG": empty,
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        # No request is ever made: the probe only opens overlays. A key is what
        # gets the pager past its "no API key" refusal.
        "XAI_API_KEY": "xai-overlay-panel-probe",
    }


def cells(pty, y: int) -> str:
    return pty.screen_lines()[y].rstrip("\n")


def panel_rows(pty, cols: int):
    """(top, bottom) screen rows of the LAST panel above the composer, or None.

    The composer is a box too, so the search runs upward from the composer's own
    top edge and takes the first complete frame above it.
    """
    lines = pty.screen_lines()
    tops = [y for y, ln in enumerate(lines) if ln.lstrip().startswith(TL)]
    bots = [y for y, ln in enumerate(lines) if ln.lstrip().startswith(BL)]
    if len(tops) < 2 or len(bots) < 2:
        return None
    # The composer is the last pair; the overlay panel is the one before it.
    return tops[-2], bots[-2]


def check_frame(pty, top: int, bot: int, cols: int, what: str):
    """Every row of the box spans exactly `cols` cells and has both walls."""
    problems = []
    head = cells(pty, top)
    tail = cells(pty, bot)
    if not head.startswith(TL) or not head.rstrip().endswith(TR):
        problems.append(f"{what}: top rule is not a closed edge: {head!r}")
    if not tail.startswith(BL) or not tail.rstrip().endswith(BR):
        problems.append(f"{what}: bottom rule is not a closed edge: {tail!r}")
    for y in range(top, bot + 1):
        row = cells(pty, y)
        # The harness grid is exactly `cols` wide; a row that ends before the
        # last column means the frame did not reach the wall.
        painted = len(row.rstrip())
        if painted != cols:
            problems.append(f"{what}: row {y} paints {painted} of {cols} cells: {row!r}")
        if top < y < bot and not (row.startswith(WALL) and row[cols - 1] == WALL):
            problems.append(f"{what}: row {y} is missing a wall: {row!r}")
    return problems


def clear(pty):
    pty.inject_keys(b"\x1b")
    pty.pump(0.3)
    pty.inject_keys(b"\x1b")
    pty.pump(0.3)
    for _ in range(80):
        pty.inject_keys(b"\x7f")
    pty.pump(0.4)


def run_width(cols: int) -> list[str]:
    bad: list[str] = []
    with tempfile.TemporaryDirectory(prefix="graff-overlay-panel-") as tmp:
        env = workspace(tmp)
        argv = [BIN, "tui", "--yolo", "--no-telemetry"]
        with PtyHarness(argv, cols=cols, rows=ROWS, cwd=tmp, env=env) as pty:
            if not pty.wait_for_boot():
                return [f"w={cols}: the TUI never took the alt screen"]

            # 1. the model picker ------------------------------------------
            pty.inject_keys(b"/model\r")
            try:
                pty.wait_for_text("Model", timeout=8.0)
            except PtyTimeout as exc:
                return [f"w={cols}: /model never opened: {exc}"]
            pty.pump(0.5)
            found = panel_rows(pty, cols)
            if found is None:
                bad.append(f"w={cols}: /model drew no bordered panel at all")
            else:
                top, bot = found
                bad += check_frame(pty, top, bot, cols, f"w={cols} /model")
                head = cells(pty, top)
                if "Model" not in head:
                    bad.append(f"w={cols}: the panel's top rule does not name it: {head!r}")
                tail = cells(pty, bot)
                if "Esc" not in tail:
                    bad.append(f"w={cols}: the panel's bottom rule lost its keys: {tail!r}")
                # DOCKED: the panel's bottom rule sits directly on the composer.
                composer_top = None
                for y in range(bot + 1, ROWS):
                    # Composer is grok-build-inset (outer_hpad_left=2); the
                    # overlay panel above it stays full-width and still docks.
                    if cells(pty, y).lstrip().startswith(TL):
                        composer_top = y
                        break
                if composer_top != bot + 1:
                    bad.append(
                        f"w={cols}: the picker floats — its last row is {bot}, "
                        f"the composer starts at {composer_top}"
                    )
                # WINDOWED: 14 rows of a longer list must say so.
                body = "\n".join(cells(pty, y) for y in range(top, bot + 1))
                if "below" not in body and "above" not in body:
                    bad.append(f"w={cols}: a windowed list gave no more-below marker")
            clear(pty)

            # 2. the completion menu wears the same frame -------------------
            pty.inject_keys(b"/")
            pty.pump(0.6)
            found = panel_rows(pty, cols)
            if found is None:
                bad.append(f"w={cols}: the slash menu drew no bordered panel")
            else:
                top, bot = found
                bad += check_frame(pty, top, bot, cols, f"w={cols} slash")
                if "Commands" not in cells(pty, top):
                    bad.append(f"w={cols}: the slash menu's rule does not name it")
            clear(pty)

            # 3. a sheet opens at its FIRST row -----------------------------
            pty.inject_keys(b"\x18")  # Ctrl+X
            try:
                pty.wait_for_text("Shortcuts", timeout=8.0)
            except PtyTimeout as exc:
                return bad + [f"w={cols}: /help never opened: {exc}"]
            pty.pump(0.4)
            screen = pty.screen_contents()
            if "prompt / scrollback" not in screen:
                bad.append(f"w={cols}: the shortcut sheet did not open at its first row")
            if "/vim-mode" in screen:
                bad.append(f"w={cols}: the shortcut sheet opened at its LAST row")
            pty.inject_keys(b"\x1b[6~" * 4)  # PgDn
            pty.pump(0.6)
            if "/vim-mode" not in pty.screen_contents():
                bad.append(f"w={cols}: paging the shortcut sheet never reached its end")
            clear(pty)

            # 4. the composer tells no story about a clipboard it never read
            pty.pump(0.4)
            screen = pty.screen_contents()
            if "Image in clipboard" in screen:
                bad.append(f"w={cols}: the composer still claims an image is in the clipboard")
            if cols >= 80 and "Ctrl+V:image" not in screen:
                bad.append(f"w={cols}: the paste key is not in the footer hint")
            # ...and the hint never runs off the edge or ends mid-word.
            hint = cells(pty, ROWS - 1)
            if len(hint.rstrip()) > cols:
                bad.append(f"w={cols}: the footer hint overruns the screen: {hint!r}")
            for cut in ("Shift+Enter:newl", "Shift+Tab:mo", "Ctrl+V:im"):
                if cut in hint and not hint.rstrip().endswith(("mode", "image", "help", "newline")):
                    bad.append(f"w={cols}: the footer hint is clipped mid-key: {hint!r}")
            pty.quit()
    return bad


def main() -> int:
    if not os.path.exists(BIN):
        print(f"notice: {BIN} not built — skipping")
        return 0
    try:
        import pty as _pty  # noqa: F401
    except Exception:
        print("notice: no pty support here — skipping")
        return 0
    problems: list[str] = []
    for cols in WIDTHS:
        problems += run_width(cols)
    if problems:
        for p in problems:
            print(f"FAIL {p}")
        return 1
    print(f"ok: overlay panels are framed, docked and top-opened at {WIDTHS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
