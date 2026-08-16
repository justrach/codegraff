#!/usr/bin/env python3
"""Live proof that the fullscreen TUI's screen only ever shows the CURRENT frame.

Everything else in the painter's battery is a unit test over bytes. This probe
puts a real `graff tui` under a pty, plays the two abuses that historically left
stale cells behind, and then reads the SCREEN back — not the byte stream — by
replaying the pty output through a small terminal model (CUP / EL / ED / CR-LF /
text, autowrap off, exactly the subset run.zig emits).

  A. resize-storm   TIOCSWINSZ is driven repeatedly mid-stream, then the session
                    is made to paint DIFFS again (typing, a second shell line).
                    The modelled screen must then equal a forced full repaint of
                    the same frame, cell for cell: any cell where they differ is
                    a cell still showing an older frame.
  B. glyph-torture  The transcript is filled with the glyphs a terminal is most
                    likely to measure differently from us (VS16 promotions, CJK,
                    emoji, box drawing) and the composer — whose border row is
                    exactly `cols` wide — is retyped over it. Same screen-state
                    equality check. This is the case where trusting visibleLen
                    on a "full" row used to strand the last cell.
  C. self-heal      With no input at all, the loop must still rewrite the screen
                    on its own clock, and the screen must still equal the frame.

Usage: python3 scripts/test-tui-painter.py [path/to/graff]  (default zig-out/bin/graff)
Exit 0 = pass (or a skip when no pty is available).
"""
import os
import re
import sys
import tempfile
import time
import unicodedata

# Absolutized BEFORE the fork: the child chdirs into its scratch workspace.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 15.0
ROWS, COLS = 30, 100
# run.zig's heal_interval_ms, plus slack for a loaded machine.
HEAL_MS = 3.0

MARK = "PAINTME"
GLYPHS = "A✓ B✓️ C日本 D\U0001f409 E╭──╮ F ok"


def drain(fd, seconds):
    # select-gated: a quiet pty blocks on read, and a blocking read would hang
    # the probe on exactly the wedged states it exists to catch.
    import select
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], min(0.1, max(end - time.time(), 0.01)))
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def boot(fd):
    out = b""
    end = time.time() + BOOT_MAX
    while time.time() < end:
        out += drain(fd, 0.3)
        if b"\x1b[?1049h" in out:
            return out + drain(fd, 1.5)
    return out


def resize(fd, rows, cols):
    import fcntl
    import struct
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn(cwd, env_extra, rows=ROWS, cols=COLS):
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo"])
    # A pty forked without a size reports 0x0 and the TUI clamps to its floor.
    resize(fd, rows, cols)
    return pid, fd


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-paint-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def reap(pid, fd):
    import signal
    try:
        os.write(fd, b"\x11")  # Ctrl+Q
        drain(fd, 2.0)
    except OSError:
        pass
    for sig in (signal.SIGKILL,):
        try:
            os.kill(pid, sig)
        except OSError:
            pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass


def cell_width(ch):
    if unicodedata.combining(ch) or ch in "​‌‍︎️⁠":
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    if ord(ch) >= 0x1F300:
        return 2
    return 1


CSI = re.compile(r"\x1b\[([0-9;?<>]*)([@-~])")


class Screen:
    """The subset of a terminal the painter can get wrong: which glyph is in
    which cell. Autowrap is off, as run.zig sets it (?7l)."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.cells = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0

    def put(self, ch, w):
        if self.r >= self.rows:
            return
        c = min(self.c, self.cols - 1)
        self.cells[self.r][c] = ch
        if w == 2 and c + 1 < self.cols:
            self.cells[self.r][c + 1] = ""
        self.c = min(c + w, self.cols)

    def erase_to_eol(self):
        if self.r >= self.rows:
            return
        for c in range(min(self.c, self.cols - 1), self.cols):
            self.cells[self.r][c] = " "

    def clear(self):
        self.cells = [[" "] * self.cols for _ in range(self.rows)]
        self.r = self.c = 0

    def feed(self, data):
        s = data.decode("utf-8", errors="replace")
        i = 0
        while i < len(s):
            ch = s[i]
            if ch == "\x1b":
                i = self.escape(s, i)
                continue
            if ch == "\r":
                self.c = 0
                i += 1
                continue
            if ch == "\n":
                self.r += 1
                i += 1
                continue
            w = cell_width(ch)
            if w:
                self.put(ch, w)
            i += 1
        return self

    def escape(self, s, i):
        rest = s[i:]
        m = CSI.match(rest)
        if m:
            self.csi(m.group(1), m.group(2))
            return i + m.end()
        if len(rest) > 1 and rest[1] in "]P_^X":
            bel = rest.find("\x07")
            st = rest.find("\x1b\\")
            ends = [e for e in (bel + 1 if bel >= 0 else -1, st + 2 if st >= 0 else -1) if e > 0]
            return i + (min(ends) if ends else len(rest))
        return i + 2

    def csi(self, params, final):
        if final == "H":
            parts = params.split(";")
            row = int(parts[0]) if parts and parts[0].isdigit() else 1
            col = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 1
            self.r, self.c = max(row - 1, 0), max(col - 1, 0)
        elif final == "J" and params in ("2", "3"):
            self.clear()
        elif final == "K" and params in ("", "0"):
            self.erase_to_eol()

    def text_rows(self):
        return ["".join(row).rstrip() for row in self.cells]

    def diff(self, other):
        for r, (a, b) in enumerate(zip(self.text_rows(), other.text_rows())):
            if a != b:
                return f"row {r}: screen has {a!r} but the frame is {b!r}"
        return None


def ground_truth(fd, rows, cols):
    """A forced full repaint, replayed onto a fresh screen: what the terminal
    WOULD show if it were redrawn from nothing right now. A resize invalidates
    run.zig's diff baseline, so the tail after the last ED is one whole frame."""
    resize(fd, rows - 1, cols)
    drain(fd, 0.5)
    resize(fd, rows, cols)
    stream = drain(fd, 1.5)
    if b"\x1b[2J\x1b[H" not in stream:
        return None
    tail = stream.rsplit(b"\x1b[2J\x1b[H", 1)[1]
    truth = Screen(rows, cols)
    truth.clear()
    return truth.feed(tail)


def check_a_resize_storm(fd, screen):
    for r, c in ((24, 80), (40, 120), (20, 60), (34, 110), (ROWS, COLS)):
        resize(fd, r, c)
        screen.feed(drain(fd, 0.25))
    screen.feed(drain(fd, 0.8))
    # Make the session paint DIFFS again on top of the post-storm baseline —
    # a full repaint right at the end would prove nothing about residue.
    os.write(fd, f"typed after the storm {MARK}".encode())
    screen.feed(drain(fd, 0.8))
    os.write(fd, b"\x15")  # Ctrl+U: clear the composer, shrinking that row
    screen.feed(drain(fd, 0.8))
    truth = ground_truth(fd, ROWS, COLS)
    if truth is None:
        return "A: no full repaint came back to compare against"
    screen.feed(b"")  # keep the modelled screen and the truth in the same frame
    return screen.diff(truth) and f"A: after a resize storm, {screen.diff(truth)}"


def check_b_glyphs(fd, screen):
    os.write(fd, f"!printf '{GLYPHS}\\n{GLYPHS}\\n'\r".encode())
    screen.feed(drain(fd, 3.0))
    # Retype over it: the composer's border row is exactly `cols` wide, so every
    # keystroke repaints a row the painter measures as full.
    # The comparison has to happen while those glyphs are still ON the screen:
    # clearing the composer first would repaint the row in plain ASCII, which
    # is exactly the width both sides agree on, and would scrub the evidence.
    for ch in ("✓️", " x", "\U0001f409", " y"):
        os.write(fd, ch.encode())
        screen.feed(drain(fd, 0.4))
    truth = ground_truth(fd, ROWS, COLS)
    if truth is None:
        return "B: no full repaint came back to compare against"
    d = screen.diff(truth)
    return d and f"B: with ambiguous-width glyphs on screen, {d}"


def check_d_winch_event(fd, pid, screen):
    """A resize EVENT with no dimension change at all. The terminal has
    reflowed (or cleared) the screen, but tty.cols()/tty.rows() answer exactly
    what they answered last pass and the frame bytes are identical, so a loop
    that only compares dimensions repaints nothing and the damage stands. The
    forced full repaint is visible as a clear-and-lay-down; the periodic heal
    never emits one, so this cannot be mistaken for the heartbeat."""
    import signal
    drain(fd, 0.4)
    os.kill(pid, signal.SIGWINCH)
    out = drain(fd, 1.2)
    screen.feed(out)
    if b"\x1b[2J\x1b[H" not in out:
        return "D: a SIGWINCH with unchanged dimensions did not force a full repaint"
    return None


def check_c_self_heal(fd, screen):
    idle = drain(fd, HEAL_MS + 1.5)
    if not idle:
        return "C: the loop wrote nothing at all while idle (no self-heal repaint)"
    screen.feed(idle)
    truth = ground_truth(fd, ROWS, COLS)
    if truth is None:
        return "C: no full repaint came back to compare against"
    d = screen.diff(truth)
    return d and f"C: after an idle self-heal, {d}"


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    try:
        screen = Screen(ROWS, COLS)
        screen.feed(boot(fd))
        os.write(fd, f"!printf '{MARK}_ONE\\n{MARK}_TWO\\n'\r".encode())
        out = drain(fd, 4.0)
        screen.feed(out)
        if MARK.encode() not in out:
            return f"the transcript never showed {MARK} (bash row missing)"
        for check in (check_a_resize_storm, check_b_glyphs, check_c_self_heal):
            err = check(fd, screen)
            if err:
                return err
        return check_d_winch_event(fd, pid, screen)
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-painter: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-painter: no pty support here — skipping")
        return 0
    try:
        err = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-painter: pty unavailable ({e}) — skipping")
            return 0
    if err:
        print(f"  ✗ painter: {err}")
        return 1
    print("  ✓ painter: screen == frame after a resize storm and a glyph torture; idle heal and SIGWINCH repaint both fire")
    return 0


if __name__ == "__main__":
    sys.exit(main())
