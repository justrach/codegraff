#!/usr/bin/env python3
"""Screen-state TUI checks, written against the virtual screen (scripts/ptyharness.py).

Same discipline as tui-pty-guard.py, one level up: instead of grepping raw pty
bytes, every assertion here reads the rows x cols grid a real terminal would
be showing. That makes the checks say what the user sees, and it unlocks a
class of test the byte probes cannot express — corrupting the screen from
OUTSIDE the child and watching whether the TUI paints its way back.

  0. interpreter    ptyharness's own selftest (no pty, no binary)
  1. mode-balance   the invariant ported from tui-pty-guard.py check A: every
                    DEC private mode the TUI latches is back to the terminal
                    default after a clean quit, and the kitty keyboard
                    push/pop depth is zero. Read off the interpreter's mode
                    bookkeeping rather than a regex over the byte stream.
  2. corruption     feed_screen() writes straight to the tty, bypassing graff
                    (a tmux status repaint, an nvim redraw, another process
                    on the same terminal). The garbage must land on the grid —
                    this is the harness proving it can SEE the damage.
  3. repaint-heals  positive control: a resize forces graff's full repaint,
                    and the grid must come back clean. Without this, check 4's
                    failure could just mean "the harness never updates".
  4. self-heal      XFAIL TODAY. Corrupt the frame, then poke the TUI so it
                    paints again, and require screen_contents() to be the
                    pre-corruption frame. graff repaints only rows whose
                    rendered text CHANGED (TUI/run.zig paint()), so out-of-band
                    damage to an unchanged row survives every diff paint. The
                    self-heal repaint lives on the sibling branch
                    fix/tui-painter; until that merges this check reports
                    expected-fail and does not break the build. When it starts
                    passing, delete the XFAIL branch below and make it a hard
                    assert. The assertion is known to be measuring healing and
                    not the harness: swap poke() for a repaint-forcing resize
                    and it flips to pass on this very branch (check 3 is that
                    control, inline).

Usage: python3 scripts/test-tui-screenstate.py [path/to/graff]  (default zig-out/bin/graff)
Exit 0 = pass (an expected-fail on check 4 is a pass). Skips (exit 0, notice)
when no pty can be allocated.
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
COLS, ROWS = 100, 30
MARK = "TMUX_SCRIBBLE_9F2A"
# Row 4 of the transcript area: above every chrome row, below nothing that
# animates, so a diff paint has no reason to rewrite it on its own.
CORRUPT_ROW = 4


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-screen-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def session(PtyHarness):
    ws, env = fresh_ws()
    return PtyHarness([BIN, "tui", "--yolo"], cols=COLS, rows=ROWS, cwd=ws, env=env)


def check_mode_balance(PtyHarness):
    h = session(PtyHarness)
    try:
        if not h.wait_for_boot():
            return "the TUI never entered the alt screen"
        h.wait_for_text("Enter:send", timeout=10)
        if not h.modes.get(1049):
            return "the alt screen is not latched while the TUI is up"
        status = h.quit()
        if status is None:
            return "quit did not exit within the window"
        latched, depth = h.mode_imbalance()
        if latched:
            return f"modes latched but never reset by clean quit: {latched}"
        if depth != 0:
            return f"kitty keyboard push/pop unbalanced (depth {depth})"
        if h.modes.get(1049):
            return "alt-screen entered but never left"
        return None
    finally:
        h.close()


def scribble():
    """An inverse-video status bar, the shape tmux and nvim actually paint."""
    return f"\x1b[{CORRUPT_ROW + 1};1H\x1b[7m{MARK} ".encode() + b"#" * 40 + b"\x1b[27m"


def poke(h):
    """Make the TUI paint again without changing the resulting frame: a
    keystroke the composer then takes back. Any self-heal repaint has every
    opportunity to fire here."""
    h.inject_keys(b"z")
    h.pump(1.0)
    h.inject_keys(b"\x7f")
    h.pump(1.5)


def check_corruption_and_healing(PtyHarness):
    """Returns (hard_error, healed, detail)."""
    h = session(PtyHarness)
    try:
        if not h.wait_for_boot():
            return "the TUI never entered the alt screen", False, ""
        h.wait_for_text("Enter:send", timeout=10)
        h.pump(2.5)  # let boot toasts (clipboard hint) age out of the frame
        before = h.screen_contents()
        before_row = h.screen_lines()[CORRUPT_ROW]

        # Out-of-band repaint: straight to the tty, graff never sees it.
        h.feed_screen(scribble())
        corrupted = h.screen_contents()
        if MARK not in corrupted:
            return "feed_screen did not reach the screen (harness cannot see the damage)", False, ""
        if corrupted == before:
            return "the grid did not change under corruption", False, ""
        # Cell-level styling survives the round trip through the real pty, so a
        # test can assert on attributes and not just glyphs.
        if not h.cell(0, CORRUPT_ROW).inverse:
            return "the scribbled cells lost their inverse attribute", False, ""

        # Positive control: a resize forces graff's full repaint, and the grid
        # must come back clean. If this fails, the harness is at fault, not the
        # painter.
        h.resize(COLS, ROWS - 1)
        h.pump(1.0)
        h.resize(COLS, ROWS)
        h.pump(1.5)
        if MARK in h.screen_contents():
            return "a forced full repaint did not clear the corruption (harness/grid fault)", False, ""

        # The real question: does ordinary activity heal out-of-band damage?
        h.pump(1.0)
        before = h.screen_contents()
        before_row = h.screen_lines()[CORRUPT_ROW]
        h.feed_screen(scribble())
        if MARK not in h.screen_contents():
            return "second corruption never landed", False, ""
        poke(h)
        after = h.screen_contents()
        healed = MARK not in after and h.screen_lines()[CORRUPT_ROW] == before_row
        detail = "" if healed else (
            f"row {CORRUPT_ROW} is {h.screen_lines()[CORRUPT_ROW]!r}, "
            f"was {before_row!r}; frames {'match' if after == before else 'differ'}"
        )
        return None, healed, detail
    finally:
        h.close()


def main():
    if not os.path.exists(BIN):
        print(f"tui-screenstate: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-screenstate: no pty support here — skipping")
        return 0
    import ptyharness

    if ptyharness._selftest() != 0:
        print("  ✗ interpreter: the VT interpreter itself is broken")
        print("tui-screenstate: 1 check(s) failed")
        return 1
    print("  ✓ interpreter: ptyharness VT selftest (--selftest for the full list)")

    failures = []
    try:
        err = check_mode_balance(ptyharness.PtyHarness)
    except OSError as e:
        # EIO on a dead pty means the CHILD vanished — a failure, not a skip.
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-screenstate: pty unavailable ({e}) — skipping")
            return 0
    if err:
        failures.append(err)
        print(f"  ✗ mode-balance: {err}")
    else:
        print("  ✓ mode-balance: every latched mode is back to default, kitty depth 0")

    err, healed, detail = check_corruption_and_healing(ptyharness.PtyHarness)
    if err:
        failures.append(err)
        print(f"  ✗ corruption: {err}")
    else:
        print(f"  ✓ corruption: out-of-band {MARK} landed on the grid, a full repaint clears it")
        if healed:
            # See the header: flip this to a hard assert once fix/tui-painter
            # is in and delete the XFAIL wording.
            print("  ✓ self-heal: XPASS — the painter repairs out-of-band damage now.")
            print("    fix/tui-painter has landed: make this a hard assert.")
        else:
            print("  ~ self-heal: XFAIL (expected on this branch) — a diff paint leaves")
            print(f"    out-of-band damage in place: {detail}")
            print("    The repair lives on fix/tui-painter; the harness proves the damage is visible.")

    if failures:
        print(f"tui-screenstate: {len(failures)} check(s) failed")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
