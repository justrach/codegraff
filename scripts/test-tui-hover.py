#!/usr/bin/env python3
"""Live proof that a clickable row LOOKS clickable before it is clicked.

?1003h motion reports already reach the loop (they drive the image-chip
preview); until TUI/hover.zig every one that missed a chip was dropped. This
probe drives the real binary under a pty, renders its output into a VIRTUAL
SCREEN (scripts/ptyharness.py) and reads CELLS back — glyph plus the pen that
wrote it — so every assertion is about what a terminal would actually show:

  1. a real tool loop against the codex mock (no network, no model) leaves one
     COLLAPSED tool summary row on screen,
  2. a motion report over that row repaints it: its cells take the theme's
     hover background, one step off the canvas, and its leading ◆ becomes the
     chevron › that announces the row opens,
  3. the row BELOW it is untouched — hover highlights a row, not a region,
  4. moving the pointer away restores the row cell for cell,
  5. a SINGLE click still expands the group, exactly as before,
  6. a DOUBLE click is ONE net toggle rather than an expand followed by a
     collapse — which is what two presses used to add up to,
  7. and a hover SWEEP across 30 rows costs a bounded number of paints, read
     off the loop's own counters (GRAFF_TUI_PAINT_STATS=1), not one per row.

Usage: python3 scripts/test-tui-hover.py [path/to/graff]
Exit 0 = pass, or a skip when there is no pty.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ptyharness import PtyHarness  # noqa: E402

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
ROWS, COLS = 34, 100
ANSWER_MAX = 30.0
NOTE_BODY = "hover-probe payload"
FINAL_REPLY = "HOVER_OK the run is done"

TOOL_MARK = "◆"  # ◆ glyphs.tool
EXPAND_MARK = "›"  # › glyphs.expand
STATS = re.compile(r"tui-paint-stats:((?: \w+=\d+)+)")

# TUI/theme_tint.zig: one step per channel, in the direction the canvas's own
# polarity asks for. Kept here as a NUMBER so a change to the constant that was
# never meant to be visible shows up as a failure rather than as a silent
# repaint of nothing.
HOVER_STEP = 16


# ----------------------------------------------------------------- helpers


def motion(h, x, y):
    """A pure ?1003h motion report — button 35, no button held. 1-based."""
    h.inject_keys(f"\x1b[<35;{x};{y}M".encode())


def click(h, x, y, settle=0.6):
    h.inject_keys(f"\x1b[<0;{x};{y}M".encode())
    h.pump(0.15)
    h.inject_keys(f"\x1b[<0;{x};{y}m".encode())
    h.pump(settle)


def row_cells(h, y):
    return [h.cell(x, y) for x in range(h.cols)]


def row_bgs(h, y):
    """The distinct backgrounds on row `y`, ignoring cells nothing painted."""
    return {c.bg for c in row_cells(h, y) if c.bg is not None}


def summary_row(h):
    for i, ln in enumerate(h.screen_lines()):
        if "Called" in ln and "tool" in ln:
            return i
    return None


def stepped(base, tint):
    """`tint` is `base` moved one step, saturating, in one consistent direction."""
    if not (isinstance(base, tuple) and isinstance(tint, tuple)):
        return False
    deltas = [t - b for b, t in zip(base, tint)]
    if all(d == 0 for d in deltas):
        return False
    if not (all(d >= 0 for d in deltas) or all(d <= 0 for d in deltas)):
        return False
    return all(abs(d) <= HOVER_STEP for d in deltas)


# ------------------------------------------------------------- mock session


def message_item(text, item_id):
    return {
        "type": "message",
        "id": item_id,
        "status": "completed",
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    }


def response_events(item, response_id):
    return [
        {"type": "response.output_item.done", "item": item},
        {
            "type": "response.completed",
            "response": {
                "id": response_id,
                "usage": {
                    "input_tokens": 100,
                    "input_tokens_details": {"cached_tokens": 0},
                    "output_tokens": 10,
                    "total_tokens": 110,
                },
            },
        },
    ]


def events(request):
    if request.ordinal == 1:
        return response_events(
            {
                "type": "function_call",
                "id": "fc_hover_read",
                "call_id": "call_hover_read",
                "name": "read_file",
                "arguments": json.dumps({"path": "note.txt"}),
                "status": "completed",
            },
            "resp_hover_read",
        )
    return response_events(message_item(FINAL_REPLY, "msg_hover_done"), "resp_hover_done")


def workspace(tmp, port):
    with open(os.path.join(tmp, "note.txt"), "w", encoding="utf-8") as fh:
        fh.write(NOTE_BODY)
    codex_home = os.path.join(tmp, "codex-home")
    os.makedirs(codex_home)
    with open(os.path.join(codex_home, "auth.json"), "w", encoding="utf-8") as fh:
        json.dump({"tokens": {"access_token": "hover-mock", "account_id": "acct-hover"}}, fh)
    harness = os.path.join(tmp, ".harness")
    os.makedirs(harness)
    with open(os.path.join(harness, "settings.json"), "w", encoding="utf-8") as fh:
        json.dump({"ai_title": False, "skills": {"codedbpro": False}}, fh)
    empty_mcp = os.path.join(tmp, "empty-mcp.json")
    with open(empty_mcp, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "HOME": tmp,
        "CODEX_HOME": codex_home,
        "GRAFF_CODEX_URL": f"http://127.0.0.1:{port}/backend-api/codex/responses",
        "GRAFF_CODEX_WS": "off",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_MCP_CONFIG": empty_mcp,
        "GRAFF_LEARN_AUTO": "off",
    }
    # Everything else the developer's shell might be exporting is UNSET (None),
    # not blanked: an empty string is a value graff would read.
    for name in list(os.environ):
        if (name.startswith("GRAFF_") or name.startswith("CODEX_") or name == "NO_COLOR") and name not in env:
            env[name] = None
    return env


def check_affordance(h):
    """(2)-(6): the tint, the mark swap, the neighbour, and the two gestures."""
    y = summary_row(h)
    if y is None:
        return f"no folded tool summary on screen\n{h.screen_contents()}"
    line = h.screen_lines()[y]
    if TOOL_MARK not in line:
        return f"the folded summary carries no tool mark: {line!r}"
    base_bgs = row_bgs(h, y)
    if len(base_bgs) != 1:
        return f"the resting row has {len(base_bgs)} backgrounds, expected the canvas alone: {base_bgs}"
    base = next(iter(base_bgs))
    below = summary_row(h) + 1
    below_before = [c.tuple() for c in row_cells(h, below)]

    # (2) the pointer lands on the row.
    motion(h, 5, y + 1)
    h.pump(0.6)
    warm = row_bgs(h, y)
    if len(warm) != 1:
        return f"the hovered row has {len(warm)} backgrounds: {warm}"
    tint = next(iter(warm))
    if not stepped(base, tint):
        return f"the hovered row's background is not one step off the canvas: {base} -> {tint}"
    hot_line = h.screen_lines()[y]
    if EXPAND_MARK not in hot_line:
        return f"the hovered collapsed row never announced that it opens: {hot_line!r}"
    if TOOL_MARK in hot_line:
        return f"the tool mark survived the swap: {hot_line!r}"

    # (3) a row is a row: the one under it is untouched, cell for cell.
    if [c.tuple() for c in row_cells(h, below)] != below_before:
        return "hovering one row repainted its neighbour too"

    # (4) leaving restores it.
    motion(h, 5, h.rows - 1)
    h.pump(0.6)
    cold = row_bgs(h, y)
    if cold != {base}:
        return f"the row kept its hover background after the pointer left: {cold}"
    if h.screen_lines()[y] != line:
        return f"the row did not come back as it was:\n  was {line!r}\n  now {h.screen_lines()[y]!r}"

    # (5) a single click still expands the group. Unchanged behaviour.
    click(h, 5, y + 1)
    if summary_row(h) is not None:
        return "a single click no longer expands the tool group"
    # ...and a single click on the open card folds it again.
    head = next((i for i, ln in enumerate(h.screen_lines()) if TOOL_MARK in ln and "read" in ln), None)
    if head is None:
        return f"the expanded card has no field-backed head\n{h.screen_contents()}"
    click(h, 5, head + 1)
    if summary_row(h) is None:
        return "a single click on the open card no longer folds it"

    # (6) a double click is ONE net toggle: it opens and STAYS open. Two
    # presses used to expand and then collapse, so the gesture looked inert.
    y = summary_row(h)
    h.inject_keys(f"\x1b[<0;5;{y + 1}M".encode())
    h.pump(0.05)
    h.inject_keys(f"\x1b[<0;5;{y + 1}m".encode())
    h.pump(0.05)
    h.inject_keys(f"\x1b[<0;5;{y + 1}M".encode())
    h.pump(0.05)
    h.inject_keys(f"\x1b[<0;5;{y + 1}m".encode())
    h.pump(0.8)
    if summary_row(h) is not None:
        return "a double click expanded the group and collapsed it again — no net effect"
    return None


# ------------------------------------------------------------ storm session


def storm_paints(tmp):
    """(7) A hover sweep rides the frame budget. Returns (err, control, swept)."""
    empty_mcp = os.path.join(tmp, "empty-mcp.json")
    with open(empty_mcp, "w", encoding="utf-8") as fh:
        fh.write('{"mcpServers": {}}')
    env = {
        "GRAFF_MCP_CONFIG": empty_mcp,
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_TUI_PAINT_STATS": "1",
    }

    def one(sweeps):
        h = PtyHarness([BIN, "tui", "--yolo"], cols=COLS, rows=ROWS, cwd=tmp, env=env)
        try:
            if not h.wait_for_boot():
                raise RuntimeError(f"the storm session never reached the alt screen\n{h.screen_contents()}")
            # A transcript worth hovering: without one every row is blank and a
            # sweep would compose the same bytes and prove nothing.
            h.inject_keys(b"!seq 1 60\r")
            h.pump(2.0)
            for _ in range(sweeps):
                for y in range(2, 32):
                    motion(h, 5, y)
                    h.pump(0.004)
            h.pump(0.6)
            h.inject_keys(b"\x11")  # Ctrl+Q — the counters print after restore
            h.pump(2.0)
            m = STATS.search(h.raw.decode(errors="replace"))
            return None if not m else {
                k: int(v) for k, v in (p.split("=") for p in m.group(1).split())
            }
        finally:
            h.close()

    control = one(0)
    if control is None:
        return "the control session printed no tui-paint-stats line", None, None
    swept = one(4)
    if swept is None:
        return "the sweep session printed no tui-paint-stats line", None, None
    extra = swept["paints"] - control["paints"]
    rows_swept = 4 * 30
    if extra < 2:
        return f"the sweep repainted {extra} times — it never highlighted anything", control, swept
    if swept["events"] - control["events"] < rows_swept * 0.9:
        return (
            f"only {swept['events'] - control['events']}/{rows_swept} motion reports reached the loop",
            control,
            swept,
        )
    # THE claim: bounded by the frame budget, not by the report count. A loop
    # that painted per report would land at ~120 here.
    if extra > rows_swept // 2:
        return (
            f"{rows_swept} hover reports cost {extra} paints — the frame budget is not folding them",
            control,
            swept,
        )
    # ...and the budget is what bounded it: frames the loop WANTED and deferred.
    if swept["skipped"] <= control["skipped"]:
        return (
            "the sweep deferred no frames at all — the paint count is low for some other reason",
            control,
            swept,
        )
    return None, control, swept


# --------------------------------------------------------------------- run


def run():
    from codex_ws_mock import CodexMock

    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        with tempfile.TemporaryDirectory(prefix="graff-hover-") as tmp:
            h = PtyHarness(
                [BIN, "tui", "--yolo", "--model", "codex", "--no-telemetry"],
                cols=COLS,
                rows=ROWS,
                cwd=tmp,
                env=workspace(tmp, port),
            )
            try:
                h.wait_for_boot()
                h.inject_keys(b"read note.txt then report\r")
                h.wait_for_text("HOVER_OK", timeout=ANSWER_MAX, settle=1.0)
                err = check_affordance(h)
                if err:
                    return err, None
            finally:
                h.close()
        with tempfile.TemporaryDirectory(prefix="graff-hover-storm-") as tmp:
            err, control, swept = storm_paints(tmp)
            if err:
                return err, None
            return None, (control, swept)
    finally:
        mock.stop()


def main():
    if not os.path.exists(BIN):
        print(f"tui-hover: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-hover: no pty support here — skipping")
        return 0
    started = time.time()
    try:
        err, stats = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err, stats = "pty EIO — the graff process died mid-check", None
        else:
            print(f"tui-hover: pty unavailable ({e}) — skipping")
            return 0
    if err:
        print(f"  ✗ hover: {err}")
        return 1
    control, swept = stats
    print(
        f"  ✓ hover: the row tints and its ◆ becomes › under the pointer, restores on leave, "
        f"single click expands and a double click is one net toggle; "
        f"120 hover reports cost {swept['paints'] - control['paints']} paints "
        f"({time.time() - started:.0f}s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
