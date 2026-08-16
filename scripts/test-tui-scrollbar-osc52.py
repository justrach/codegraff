#!/usr/bin/env python3
"""Live proof for the scroll gutter and the OSC 52 clipboard channel.

Both features are invisible to a unit test in the way that matters: one is a
glyph that has to land on a specific CELL of a real terminal, the other is a
byte string that has to leave the process. So this probe drives the real binary
under a pty, reads the virtual screen back (scripts/ptyharness.py), and checks:

  A. thumb      scroll off the tail and the LAST column of the viewport shows a
                contiguous run of thumb glyphs, inside the transcript band and
                nowhere else — not on the top bar, not on the composer.
  B. travel     scrolling back toward the tail moves that run DOWN the track.
  C. no residue back at the tail, past the fade window, no thumb survives
                anywhere on the grid — and the last column of every row is
                identical to what a FORCED FULL REPAINT of the same frame puts
                there. A diff paint that skipped the gutter rows would leave a
                glyph the full repaint does not, and this is what catches it.
  D. osc52      a drag-copy puts `ESC ] 52 ; c ; <base64> BEL` on the wire, and
                the base64 decodes to exactly the screen rows the drag covered.
                Asserted against the BYTE STREAM, because that is the thing an
                SSH client on the far end actually receives.

Usage: python3 scripts/test-tui-scrollbar-osc52.py [path/to/graff]
       (default zig-out/bin/graff).  Exit 0 = pass; skips (exit 0) with no pty.
"""
import base64
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
COLS, ROWS = 100, 30
THUMB = "❚"
MARK = "GUTTERMARK_QX"
FADE = 1.5  # TUI/scrollbar.zig fade_ms
OSC52 = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07")

WHEEL_UP = b"\x1b[<64;40;10M"
WHEEL_DOWN = b"\x1b[<65;40;10M"


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-gutter-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def fill(h, blocks=8):
    """Transcript content with no model call: `!` lines run in-session, so the
    text on screen is known exactly and nothing streams while we scroll."""
    for tag in range(blocks):
        body = "%s filler %d-%d padded out so the transcript outruns the viewport"
        lines = "".join((body % (MARK, tag, k)) + r"\n" for k in range(4))
        h.inject_keys((r"!printf '" + lines + r"'" + "\r").encode())
        h.pump(1.0)
    h.pump(1.5)


def thumb_rows(h):
    """Rows whose LAST column carries the thumb."""
    return [y for y in range(ROWS) if h.cell(COLS - 1, y).ch == THUMB]


def last_column(h):
    return [h.cell(COLS - 1, y).ch for y in range(ROWS)]


def full_repaint(h):
    """A resize invalidates run.zig's diff baseline, so what follows is one
    whole frame laid down from a cleared screen."""
    h.resize(COLS, ROWS - 1)
    h.pump(0.6)
    h.resize(COLS, ROWS)
    h.pump(1.5)


def sgr(btn, col, row, press=True):
    return f"\x1b[<{btn};{col};{row}{'M' if press else 'm'}".encode()


def check_thumb(h):
    # Nothing has scrolled yet: no gutter on a tail-parked viewport.
    if thumb_rows(h):
        return "the gutter is up before anything scrolled", None
    for _ in range(5):
        h.inject_keys(WHEEL_UP)
        h.pump(0.25)
    h.pump(0.5)
    rows = thumb_rows(h)
    if not rows:
        return "scrolling off the tail raised no thumb on the last column", None
    if rows != list(range(rows[0], rows[0] + len(rows))):
        return f"the thumb is not one contiguous run: {rows}", None
    # It has to be INSIDE the transcript, not on the chrome. The composer box
    # is the last thing on screen and draws its own right wall, so a thumb on
    # it would be sitting on that wall.
    lines = h.screen_lines()
    box_rows = [y for y, ln in enumerate(lines) if "│" in ln or "╰" in ln or "╭" in ln]
    if box_rows and rows[-1] >= min(box_rows):
        return f"the thumb reached the composer: rows {rows}, box starts at {min(box_rows)}", None
    if rows[0] == 0:
        return "the thumb is on the top bar, not in the viewport", None
    # And it is the ONLY place that glyph appears — a gutter that also printed
    # into the body would be indistinguishable from content.
    stray = [(x, y) for y in range(ROWS) for x in range(COLS - 1) if h.cell(x, y).ch == THUMB]
    if stray:
        return f"the thumb glyph appears off the last column at {stray[:3]}", None
    return None, rows


def check_travel(h, high):
    for _ in range(3):
        h.inject_keys(WHEEL_DOWN)
        h.pump(0.25)
    h.pump(0.5)
    low = thumb_rows(h)
    if not low:
        return "the gutter vanished while still scrolled off the tail", None
    if low[0] <= high[0]:
        return f"scrolling toward the tail did not move the thumb down ({high} -> {low})", None
    return None, low


def check_no_residue(h):
    # All the way back to the tail, then past the fade window.
    for _ in range(24):
        h.inject_keys(WHEEL_DOWN)
        h.pump(0.06)
    h.pump(FADE + 1.0)
    left = thumb_rows(h)
    if left:
        return f"the gutter never faded at the tail: rows {left}"
    everywhere = [(x, y) for y in range(ROWS) for x in range(COLS) if h.cell(x, y).ch == THUMB]
    if everywhere:
        return f"a thumb glyph survived somewhere on the grid: {everywhere[:3]}"
    # The equality check that makes "no residue" mean something: the diff paint
    # that took the gutter away must have left the screen where a full repaint
    # of the same frame would.
    diffed = last_column(h)
    full_repaint(h)
    fresh = last_column(h)
    if diffed != fresh:
        bad = [i for i, (a, b) in enumerate(zip(diffed, fresh)) if a != b]
        return (
            f"the last column differs from a forced full repaint at rows {bad[:5]}: "
            f"{[diffed[i] for i in bad[:5]]!r} vs {[fresh[i] for i in bad[:5]]!r}"
        )
    return None


def check_osc52(h):
    """Drag two known rows and read the escape off the wire."""
    lines = h.screen_lines()
    hits = [i for i, ln in enumerate(lines) if MARK in ln]
    if len(hits) < 3:
        return f"not enough {MARK} rows on screen to drag ({len(hits)})"
    first, last = hits[0], hits[0] + 1
    seen = len(h.raw)
    h.inject_keys(sgr(0, 1, first + 1))
    h.pump(0.35)
    h.inject_keys(sgr(32, COLS, last + 1))
    h.pump(0.5)
    if b"\x1b[7m" not in bytes(h.raw[seen:]):
        return "the drag painted no inverse-video band, so nothing was selected"
    before_release = len(h.raw)
    if OSC52.search(bytes(h.raw[seen:])):
        return "an OSC 52 escape went out before the button was released"
    h.inject_keys(sgr(0, COLS, last + 1, press=False))
    h.pump(1.5)
    tail = bytes(h.raw[before_release:])
    found = OSC52.findall(tail)
    if not found:
        return "the release emitted no OSC 52 sequence"
    if len(found) > 1:
        return f"the release emitted {len(found)} OSC 52 sequences; a clipboard write happens once"
    try:
        payload = base64.b64decode(found[0], validate=True).decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return f"the OSC 52 body is not valid base64 ({e})"
    # The band survives the release, so the rows on screen right now ARE the
    # rows that were copied. Text-only capture: each row loses its padding.
    want = "\n".join(h.screen_lines()[first:last + 1]).rstrip()
    want = "\n".join(ln.rstrip() for ln in want.split("\n"))
    if payload != want:
        return f"OSC 52 carried {payload!r}, but the dragged rows read {want!r}"
    if MARK not in payload:
        return f"the OSC 52 payload does not contain {MARK}: {payload!r}"
    return None


def run(PtyHarness):
    ws, env = fresh_ws()
    h = PtyHarness([BIN, "tui", "--yolo"], cols=COLS, rows=ROWS, cwd=ws, env=env)
    try:
        if not h.wait_for_boot():
            return "the TUI never entered the alt screen"
        h.wait_for_text("Enter:send", timeout=10)
        fill(h)
        if MARK not in h.screen_contents():
            return f"the transcript never showed {MARK} (no `!` output)"
        err, high = check_thumb(h)
        if err:
            return err
        print(f"    thumb: rows {high[0]}..{high[-1]} on column {COLS - 1}")
        err, low = check_travel(h, high)
        if err:
            return err
        print(f"    travel: {high[0]}..{high[-1]} -> {low[0]}..{low[-1]} toward the tail")
        err = check_no_residue(h)
        if err:
            return err
        print("    residue: gutter faded, last column == a forced full repaint")
        err = check_osc52(h)
        if err:
            return err
        print("    osc52: the wire carried the exact base64 of the dragged rows")
        return None
    finally:
        h.close()


def main():
    if not os.path.exists(BIN):
        print(f"tui-scrollbar-osc52: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-scrollbar-osc52: no pty support here — skipping")
        return 0
    import ptyharness

    # The local half of the copy writes the real clipboard; put it back.
    saved = None
    if sys.platform == "darwin":
        try:
            saved = subprocess.run(["pbpaste"], capture_output=True, check=True).stdout
        except Exception:  # noqa: BLE001
            saved = None
    try:
        err = run(ptyharness.PtyHarness)
    except ptyharness.PtyTimeout as e:
        err = str(e).splitlines()[0]
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-scrollbar-osc52: pty unavailable ({e}) — skipping")
            return 0
    finally:
        if saved is not None:
            try:
                subprocess.run(["pbcopy"], input=saved, check=False)
            except Exception:  # noqa: BLE001
                pass
    if err:
        print(f"  ✗ scrollbar/osc52: {err}")
        return 1
    print("  ✓ scrollbar/osc52: the gutter tracks the viewport and leaves no residue; a copy reaches the terminal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
