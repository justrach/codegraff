#!/usr/bin/env python3
"""Live proof: scrolling the transcript is a terminal-side SCROLL, and it lies
about nothing.

The diff painter compares screen row i to the previous frame's row i, so a
one-line scroll makes EVERY row differ and the whole screen is rewritten per
wheel notch. TUI/scrollpaint.zig instead sets a scroll region over the band that
moved, emits SU/SD, and repaints only the rows the scroll exposed. That is a
correctness risk exactly where it is a performance win: if the region, the
direction or the exposed rows are off by one, the screen quietly stops matching
the frame and NOTHING says so — the next paint diffs against a model of the
screen that is no longer true.

So this probe drives the real binary under a pty and checks both halves:

  A. cheap   one wheel notch must cost a small fraction of a full repaint, and
             must contain a scroll-region + SU/SD rather than a screenful of
             rows. Reported as bytes, measured live.
  B. honest  after a storm of wheel notches in both directions (plus keyboard
             scrolling, a fold toggle mid-storm and a page jump), the modelled
             screen — replayed through a terminal that understands DECSTBM /
             SU / SD — must equal a FORCED FULL REPAINT of the same frame, cell
             for cell. Any cell where they differ is a cell the scroll path
             moved somewhere the composer did not.
  C. tidy    the scroll region must not be left set. A margin that outlives the
             paint turns every later LF into a scroll inside it.

Usage: python3 scripts/test-tui-scroll-paint.py [path/to/graff]
       (default zig-out/bin/graff).  Exit 0 = pass; skips (exit 0) with no pty.
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
TAIL = "SCROLLTAILOMEGA"
# One wheel notch is 3 lines out of a ~24-row band: comfortably under a quarter
# of a full repaint even with the sticky header and status bar changing too.
BUDGET = 0.25

WHEEL_UP = b"\x1b[<64;40;10M"
WHEEL_DOWN = b"\x1b[<65;40;10M"


def drain(fd, seconds):
    # select-gated: a quiet pty blocks on read, and a blocking read here would
    # hang the probe on exactly the wedged states it exists to catch.
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
    ws = tempfile.mkdtemp(prefix="tui-scroll-")
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
    for sig in (signal.SIGTERM, signal.SIGKILL):
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
    """The subset of a terminal the painter can get wrong, plus the two
    sequences the scroll path adds: DECSTBM margins and SU/SD. Autowrap is off,
    as run.zig sets it (?7l)."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.cells = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.top, self.bot = 0, rows - 1
        self.margins_seen = 0
        self.scrolls = 0

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

    def scroll(self, n, up):
        self.scrolls += 1
        blank = [" "] * self.cols
        for _ in range(n):
            if up:
                for r in range(self.top, self.bot):
                    self.cells[r] = self.cells[r + 1]
                self.cells[self.bot] = list(blank)
            else:
                for r in range(self.bot, self.top, -1):
                    self.cells[r] = self.cells[r - 1]
                self.cells[self.top] = list(blank)

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
                # Inside the margins an LF at the bottom scrolls; the painter
                # only ever emits LF on the full lay-down, with no margins set.
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
        if params.startswith(("?", "<", ">")):
            return
        parts = params.split(";")

        def num(k, dflt):
            return int(parts[k]) if len(parts) > k and parts[k].isdigit() else dflt

        if final == "H":
            self.r, self.c = max(num(0, 1) - 1, 0), max(num(1, 1) - 1, 0)
        elif final == "J" and params in ("2", "3"):
            self.clear()
        elif final == "K" and params in ("", "0"):
            self.erase_to_eol()
        elif final == "r":
            self.top = max(num(0, 1) - 1, 0)
            self.bot = min(num(1, self.rows) - 1, self.rows - 1)
            if params:
                self.margins_seen += 1
            self.r, self.c = self.top, 0
        elif final == "S":
            self.scroll(max(num(0, 1), 1), True)
        elif final == "T":
            self.scroll(max(num(0, 1), 1), False)

    def text_rows(self):
        return ["".join(row).rstrip() for row in self.cells]

    def diff(self, other):
        for r, (a, b) in enumerate(zip(self.text_rows(), other.text_rows())):
            if a != b:
                return f"row {r}: screen has {a!r} but the frame is {b!r}"
        return None


def paints(stream):
    """One entry per PAINT. run.zig wraps each in the ?2026 synchronized-update
    bracket, which is the only way to tell one paint from the next in a stream
    that also carries the 3-second self-heal — and a heal landing inside the
    window would otherwise be billed to the wheel notch being measured."""
    return re.findall(rb"\x1b\[\?2026h(.*?)\x1b\[\?2026l", stream, re.S)


def ground_truth(fd, rows, cols):
    """A forced full repaint, replayed onto a fresh screen: what the terminal
    WOULD show if it were redrawn from nothing right now. A resize invalidates
    run.zig's diff baseline, so the paint that follows one is a whole frame."""
    resize(fd, rows - 1, cols)
    drain(fd, 0.5)
    resize(fd, rows, cols)
    stream = drain(fd, 1.5)
    full = [p for p in paints(stream) if b"\x1b[2J\x1b[H" in p]
    if not full:
        return None, 0
    truth = Screen(rows, cols)
    truth.clear()
    return truth.feed(full[-1]), len(full[-1])


def fill(fd):
    """Transcript content with no model call: `!` lines run in-session, so the
    text on screen is known exactly and nothing streams while we scroll."""
    for tag in range(8):
        body = "filler line %d-%d padded out so the transcript is far longer than the viewport"
        lines = "".join((body % (tag, k)) + r"\n" for k in range(4))
        os.write(fd, (r"!printf '" + lines + r"'" + "\r").encode())
        drain(fd, 1.2)
    os.write(fd, (r"!printf '" + TAIL + r"\n'" + "\r").encode())
    return drain(fd, 2.5)


def check_a_cheap(fd, screen):
    truth, full_bytes = ground_truth(fd, ROWS, COLS)
    if truth is None:
        return "A: no full repaint came back to size the budget against", None
    screen.feed(b"")
    # Off the bottom first, so the notch measured below is a plain slide with
    # transcript on both sides of it rather than a clamp at the tail.
    for _ in range(4):
        os.write(fd, WHEEL_UP)
        screen.feed(drain(fd, 0.35))
    os.write(fd, WHEEL_UP)
    stream = drain(fd, 0.8)
    screen.feed(stream)
    # The notch's OWN paint, not whatever else the 0.8s window caught.
    scrolled = [p for p in paints(stream) if re.search(rb"\x1b\[\d+[ST]", p)]
    if not scrolled:
        return "A: a wheel notch emitted no SU/SD — the fast path never fired", None
    one = scrolled[-1]
    if not re.search(rb"\x1b\[\d+;\d+r", one):
        return "A: the scroll was emitted with no DECSTBM region around it", None
    if len(one) >= full_bytes * BUDGET:
        return (
            f"A: a wheel notch cost {len(one)} bytes against a {full_bytes}-byte full repaint "
            f"(budget {BUDGET:.0%})"
        ), None
    return None, (len(one), full_bytes)


def check_b_honest(fd, screen):
    storm = (
        [WHEEL_UP] * 9
        + [WHEEL_DOWN] * 4
        + [b"\x0b"] * 3          # Ctrl+K: keyboard scroll, one line at a time
        + [WHEEL_UP] * 6
        + [b"\x1b[5~"]           # PageUp: a jump far larger than the band
        + [WHEEL_DOWN] * 5
        + [WHEEL_UP] * 2
        + [b"\x1b[6~"]           # PageDown back
        + [WHEEL_DOWN] * 8
        + [WHEEL_UP] * 3
    )
    for ev in storm:
        os.write(fd, ev)
        screen.feed(drain(fd, 0.18))
    screen.feed(drain(fd, 0.8))
    if screen.scrolls == 0:
        return "B: the storm never took the scroll path at all"
    truth, _ = ground_truth(fd, ROWS, COLS)
    if truth is None:
        return "B: no full repaint came back to compare against"
    screen.feed(b"")
    d = screen.diff(truth)
    return d and f"B: after a scroll storm of {screen.scrolls} scrolls, {d}"


def check_c_tidy(screen):
    if (screen.top, screen.bot) != (0, ROWS - 1):
        return f"C: the scroll region was left at rows {screen.top}-{screen.bot}"
    if screen.margins_seen == 0:
        return "C: no DECSTBM was ever set, so nothing was proven about resetting it"
    return None


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    try:
        screen = Screen(ROWS, COLS)
        screen.feed(boot(fd))
        out = fill(fd)
        screen.feed(out)
        if TAIL.encode() not in out:
            return f"the transcript never showed {TAIL} (no `!` output)"
        err, nums = check_a_cheap(fd, screen)
        if err:
            return err
        print(f"    one wheel notch: {nums[0]} bytes vs {nums[1]} for a full repaint "
              f"({nums[0] / nums[1]:.1%})")
        err = check_b_honest(fd, screen)
        if err:
            return err
        print(f"    storm: {screen.scrolls} hardware scrolls, screen == frame")
        return check_c_tidy(screen)
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-scroll-paint: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-scroll-paint: no pty support here — skipping")
        return 0
    try:
        err = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-scroll-paint: pty unavailable ({e}) — skipping")
            return 0
    if err:
        print(f"  ✗ scroll-paint: {err}")
        return 1
    print("  ✓ scroll-paint: a wheel notch is a scroll region + SU, and a storm of them leaves the screen == the frame")
    return 0


if __name__ == "__main__":
    sys.exit(main())
