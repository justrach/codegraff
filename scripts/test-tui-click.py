#!/usr/bin/env python3
"""Live proof that a SINGLE click does something.

Hover, the wheel, drag-copy and the scroll thumb all shipped before this; the
press itself still only focused the composer, toggled a fold, or dismissed
whatever overlay was up. Every list on screen looked clickable and was not.
This probe drives the real binary under a pty, renders its output into a
VIRTUAL SCREEN (scripts/ptyharness.py) and reads CELLS back, so each assertion
is about what a terminal would actually show:

  1. click-vs-drag  a press and a release on the SAME cell with no motion in
                    between paints no inverse-video band and copies nothing —
                    a click is not a one-cell selection — while the SAME press
                    with motion in it does paint one,
  2. gutter seek    a press on the last column jumps the viewport toward that
                    position, and never anchors a selection there,
  3. gutter drag    holding the button and moving down the track walks the
                    viewport continuously, still without a band,
  4. list rows      a click on an overlay row moves the highlight to it, a
                    second click on that row confirms it like Enter, and a
                    click on the backdrop below the panel dismisses it,
  5. slash menu     a click on the highlighted completion row runs it.

The tool fold's own click lives in scripts/test-tui-hover.py, which already
runs a real tool loop and asserts a single click expands the group and a double
click is one net toggle.

Nothing here needs a model: `!cmd` lines run in-session, so the transcript is
known exactly and nothing streams while the mouse is moving.

Usage: python3 scripts/test-tui-click.py [path/to/graff]
Exit 0 = pass, or a skip when there is no pty.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ptyharness import PtyHarness  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
COLS, ROWS = 100, 30
THUMB = "❚"  # glyphs.scroll_thumb
MARK = "CLICKMARK_QX"
BAND = b"\x1b[7m"  # the drag-selection band's inverse video
OSC52 = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07")
WHEEL_UP = b"\x1b[<64;40;10M"
WHEEL_DOWN = b"\x1b[<65;40;10M"


# ----------------------------------------------------------------- helpers


def sgr(btn, col, row, press=True):
    return f"\x1b[<{btn};{col};{row}{'M' if press else 'm'}".encode()


def click(h, col, row, settle=0.45):
    """A CLICK: press and release on one cell, with nothing in between."""
    h.inject_keys(sgr(0, col, row))
    h.pump(0.12)
    h.inject_keys(sgr(0, col, row, press=False))
    h.pump(settle)


def thumb_rows(h):
    return [y for y in range(ROWS) if h.cell(COLS - 1, y).ch == THUMB]


def fill(h, blocks=9):
    for tag in range(blocks):
        body = "%s filler %d-%d padded out so the transcript outruns the viewport"
        lines = "".join((body % (MARK, tag, k)) + r"\n" for k in range(4))
        h.inject_keys((r"!printf '" + lines + r"'" + "\r").encode())
        h.pump(0.9)
    h.pump(1.2)


def workspace():
    ws = tempfile.mkdtemp(prefix="tui-click-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "GRAFF_MCP_CONFIG": empty,
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_NO_TELEMETRY": "1",
    }
    for name in list(os.environ):
        if (name.startswith("GRAFF_") or name == "NO_COLOR") and name not in env:
            env[name] = None
    return ws, env


# ------------------------------------------------------------------ checks


def check_click_is_not_drag(h):
    """(1) A motionless press+release selects nothing and copies nothing."""
    rows = [i for i, ln in enumerate(h.screen_lines()) if MARK in ln]
    if len(rows) < 2:
        return f"no {MARK} rows to click on\n{h.screen_contents()}"
    seen = len(h.raw)
    click(h, 8, rows[1] + 1, settle=1.2)
    after = bytes(h.raw[seen:])
    if BAND in after:
        return "a motionless click painted a selection band"
    if OSC52.search(after):
        return "a motionless click wrote the clipboard"
    if "copied" in h.screen_contents():
        return "a motionless click claimed it copied something"
    # ...and the control: the SAME press, moved, is a selection.
    seen = len(h.raw)
    h.inject_keys(sgr(0, 8, rows[0] + 1))
    h.pump(0.2)
    h.inject_keys(sgr(32, 60, rows[1] + 1))
    h.pump(0.5)
    if BAND not in bytes(h.raw[seen:]):
        return "a press that MOVED painted no band — the control never engaged"
    h.inject_keys(sgr(0, 60, rows[1] + 1, press=False))
    h.pump(0.8)
    h.inject_keys(b"\x1b")  # drop the band before anything else runs
    h.pump(0.4)
    return None


def track(h):
    """The gutter's first and last row, calibrated off the thumb's extremes."""
    for _ in range(60):
        h.inject_keys(WHEEL_UP)
        h.pump(0.02)
    h.pump(0.8)
    top = thumb_rows(h)
    if not top:
        return None, "scrolling to the top raised no thumb"
    for _ in range(80):
        h.inject_keys(WHEEL_DOWN)
        h.pump(0.02)
    h.pump(0.8)
    bottom = thumb_rows(h)
    if not bottom:
        return None, "the thumb vanished before the tail was reached"
    return (top[0], bottom[-1]), None


def to_tail(h):
    for _ in range(80):
        h.inject_keys(WHEEL_DOWN)
        h.pump(0.02)
    h.pump(0.8)


def check_gutter_seek(h, first, last):
    """(2) A press on the track jumps the viewport, and anchors no band.

    Both directions start from the far end, so neither assertion can pass
    because the viewport happened to already be where it was aimed."""
    to_tail(h)
    at_tail = thumb_rows(h)
    if not at_tail or at_tail[-1] != last:
        return f"the wheel did not park the viewport at the tail: {at_tail}"
    seen = len(h.raw)
    click(h, COLS, first + 1, settle=0.9)
    if BAND in bytes(h.raw[seen:]):
        return "a press on the gutter anchored a selection band"
    rows = thumb_rows(h)
    if not rows:
        return "the gutter disappeared after a press on its own track"
    if rows[0] != first:
        return f"a press on the top of the track left the thumb at {rows[0]}, wanted {first}"
    if f"{MARK} filler 0-0" not in h.screen_contents():
        return f"the top of the track did not show the top of the transcript\n{h.screen_contents()}"
    click(h, COLS, last + 1, settle=0.9)
    rows = thumb_rows(h)
    if not rows or rows[-1] != last:
        return f"a press on the bottom of the track left the thumb at {rows[-1:]}, wanted {last}"
    if f"{MARK} filler 8-3" not in h.screen_contents():
        return "the bottom of the track did not show the tail of the transcript"
    return None


def check_gutter_drag(h, first, last):
    """(3) Holding the button and moving walks the viewport, band-free."""
    to_tail(h)
    seen = len(h.raw)
    h.inject_keys(sgr(0, COLS, first + 1))
    h.pump(0.3)
    started = thumb_rows(h)
    if not started or started[0] != first:
        return f"the drag's opening press did not take the thumb to the top: {started}"
    walked = [started[:1]]
    step = first
    while step < last:
        step += max(1, (last - first) // 5)
        h.inject_keys(sgr(32, COLS, min(step, last) + 1))
        h.pump(0.25)
        rows = thumb_rows(h)
        if not rows:
            return "the gutter vanished mid-drag"
        walked.append(rows[:1])
    h.inject_keys(sgr(0, COLS, last + 1, press=False))
    h.pump(0.6)
    if BAND in bytes(h.raw[seen:]):
        return "a gutter drag painted a selection band"
    tops = [w[0] for w in walked]
    if tops != sorted(tops):
        return f"the drag did not walk the thumb monotonically down: {tops}"
    if tops[-1] <= tops[0]:
        return f"the drag never moved the thumb: {tops}"
    return None


def unwall(line):
    """A panel body row with its side walls taken off."""
    s = line.strip()
    if s.startswith("\u2502"):
        s = s[1:]
    if s.endswith("\u2502"):
        s = s[:-1]
    return s


def panel_rows(h, title):
    """(row, text) of every body row of the open panel named `title`.

    The name lives in the panel's TOP EDGE (`\u256d\u2500 Theme \u2500\u2500\u256e`), not in a body
    row of its own, so the header is found on the border and the rows are the
    walled lines under it, up to the closing edge.
    """
    lines = h.screen_lines()
    head = next(
        (i for i, ln in enumerate(lines) if ln.lstrip().startswith("\u256d") and title in ln),
        None,
    )
    if head is None:
        return None
    out = []
    for i in range(head + 1, ROWS):
        raw = lines[i].strip()
        if raw.startswith("\u2570"):  # the closing edge ends the panel
            break
        if not raw.startswith("\u2502"):
            break
        text = unwall(lines[i]).strip()
        if not text:
            continue
        if text.startswith("\u203a"):
            text = text[1:].strip()
        # The "\u2026 N below" window marker is chrome, not a pickable row.
        if text.startswith("\u2026"):
            continue
        out.append((i, text.split("  (current)")[0].strip()))
    return out


def check_list_rows(h):
    """(4) Select, confirm, dismiss — the three things a panel owes a click."""
    h.inject_keys(b"/theme\r")
    h.pump(1.0)
    rows = panel_rows(h, "Theme")
    if not rows or len(rows) < 3:
        return f"the theme panel did not open\n{h.screen_contents()}"
    row, label = rows[2]
    click(h, 4, row + 1, settle=0.7)
    if panel_rows(h, "Theme") is None:
        return "the first click on a row closed the panel instead of selecting"
    marked = [ln for ln in h.screen_lines() if "›" in ln and label in ln]
    if not marked:
        return f"the first click did not move the highlight onto {label!r}"
    click(h, 4, row + 1, settle=0.9)
    if panel_rows(h, "Theme") is not None:
        return "the second click on the highlighted row did not confirm it"
    if label not in h.screen_contents():
        return f"confirming did not report the picked row {label!r}"
    # ...and the backdrop dismisses it, like Esc. The panel DOCKS to the
    # composer, so the empty band is ABOVE it, not below.
    h.inject_keys(b"/theme\r")
    h.pump(1.0)
    rows = panel_rows(h, "Theme")
    if not rows:
        return "the theme panel did not reopen"
    top = rows[0][0] - 1  # the panel's top edge
    above = top - 2
    if above < 1:
        return f"no backdrop above the panel to click (top edge at {top})"
    click(h, 4, above + 1, settle=0.8)
    if panel_rows(h, "Theme") is not None:
        return "a click on the backdrop above the panel left it open"
    return None


def check_slash_row(h):
    """(5) The completion menu's highlighted row runs on a click."""
    h.inject_keys(b"/theme")
    h.pump(0.8)
    lines = h.screen_lines()
    hit = next((i for i, ln in enumerate(lines) if "›" in ln and "/theme" in ln), None)
    if hit is None:
        return f"the completion menu never offered /theme\n{h.screen_contents()}"
    click(h, 4, hit + 1, settle=1.0)
    if panel_rows(h, "Theme") is None:
        return "a click on the highlighted completion row did not run it"
    h.inject_keys(b"\x1b")
    h.pump(0.4)
    return None


# --------------------------------------------------------------------- run


def run():
    ws, env = workspace()
    h = PtyHarness([BIN, "tui", "--yolo"], cols=COLS, rows=ROWS, cwd=ws, env=env)
    try:
        if not h.wait_for_boot():
            return f"the session never reached the alt screen\n{h.screen_contents()}"
        fill(h)
        err = check_click_is_not_drag(h)
        if err:
            return err
        bounds, err = track(h)
        if err:
            return err
        first, last = bounds
        if last - first < 4:
            return f"the gutter track is too short to aim at: rows {first}..{last}"
        err = check_gutter_seek(h, first, last)
        if err:
            return err
        err = check_gutter_drag(h, first, last)
        if err:
            return err
        err = check_list_rows(h)
        if err:
            return err
        return check_slash_row(h)
    finally:
        h.close()


def main():
    if not os.path.exists(BIN):
        print(f"tui-click: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-click: no pty support here — skipping")
        return 0
    started = time.time()
    try:
        err = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-click: pty unavailable ({e}) — skipping")
            return 0
    if err:
        print(f"  ✗ click: {err}")
        return 1
    print(
        "  ✓ click: a motionless click selects nothing, the gutter seeks and drags without a "
        f"band, a list row selects then confirms, the backdrop dismisses ({time.time() - started:.0f}s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
