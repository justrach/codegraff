#!/usr/bin/env python3
"""PtyHarness: a real pty plus a VIRTUAL SCREEN, for replicable TUI tests.

The older probes (scripts/tui-pty-guard.py, scripts/test-tui-selection.py)
assert on RAW pty bytes: they grep the stream for `\\x1b[7m`, re-derive row
indices by splitting on `\\x1b[2J\\x1b[H`, and force full repaints just to get
readable output. That works, but every assertion has to know how graff paints.

grok-build's PtyHarness takes the other road, and this is the port of it: spawn
the binary on a pty, feed everything it writes through a small VT interpreter
into a rows x cols cell grid, then assert on what a terminal WOULD SHOW —
`screen_contents()`, `wait_for_text()`, `cell(x, y)`. Diff paints, full paints
and `CSI row;1H` addressing all collapse into the same grid, so a test says
what the user sees instead of how the bytes got there.

It also does what a raw-byte probe cannot: `feed_screen()` writes straight to
the SLAVE fd, so the bytes reach the screen without passing through the child.
That is a tmux status line, an nvim repaint, or a stray `printf` from another
process scribbling over graff's frame — the exact corruption a self-healing
painter has to repair.

Dependency-free by design (stdlib only, no pyte): tier-1 runs on whatever
python3 the machine has.

Covered, because it is what graff emits (TUI/run.zig, TUI/restore.zig):
  CUP/HVP, CUU/CUD/CUF/CUB, CHA/VPA, ED, EL, ECH, ICH/DCH, IL/DL, SU/SD
  SGR (fg/bg/inverse/bold tracked per cell, bce erase takes the current bg)
  DECSET/DECRST private modes, recorded (1049 alt screen, 2004, 2026, 25,
    7 autowrap, 1000/1002/1003/1006 mouse)
  kitty keyboard push/pop depth (CSI > u / CSI < u), modifyOtherKeys
  OSC / DCS / APC / SOS / PM swallowed (kitty graphics, OSC 11 bg query)
  autowrap-off semantics: the cursor pins to the last column, it never wraps
  TIOCSWINSZ-driven resize of both the tty and the grid

Self-check (no pty, no binary needed):  python3 scripts/ptyharness.py --selftest
"""

from __future__ import annotations

import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
import unicodedata

# DEC private modes whose TERMINAL DEFAULT is enabled: autowrap and cursor
# visible. For those the restore direction is `h`, so "balanced" means "final
# state == default", not "every h has a later l".
DEFAULT_ON_MODES = {7, 25}

CSI_RE = re.compile(rb"\x1b\[([\x30-\x3f]*)([\x20-\x2f]*)([\x40-\x7e])")
_PARAM_OR_INTER = set(range(0x20, 0x40))

KEYS = {
    "enter": b"\r",
    "esc": b"\x1b",
    "tab": b"\t",
    "backspace": b"\x7f",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "ctrl-c": b"\x03",
    "ctrl-q": b"\x11",
}


class PtyFailure(RuntimeError):
    pass


class PtyTimeout(PtyFailure):
    pass


class Cell:
    """One screen cell: the glyph plus the pen that wrote it."""

    __slots__ = ("ch", "fg", "bg", "inverse", "bold")

    def __init__(self, ch=" ", fg=None, bg=None, inverse=False, bold=False):
        self.ch = ch
        self.fg = fg
        self.bg = bg
        self.inverse = inverse
        self.bold = bold

    def __eq__(self, other):
        return isinstance(other, Cell) and self.tuple() == other.tuple()

    def tuple(self):
        return (self.ch, self.fg, self.bg, self.inverse, self.bold)

    def __repr__(self):
        return f"Cell({self.ch!r}, fg={self.fg}, bg={self.bg}, inv={self.inverse}, bold={self.bold})"


def char_width(ch: str) -> int:
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def _incomplete_utf8_tail(run: bytes) -> int:
    """Bytes at the end of `run` that begin a multi-byte char but do not finish it."""
    for back in range(1, min(4, len(run)) + 1):
        b = run[-back]
        if b < 0x80:
            return 0
        if b >= 0xC0:
            need = 2 if b < 0xE0 else 3 if b < 0xF0 else 4
            return back if back < need else 0
    return 0


class Screen:
    """A rows x cols cell grid driven by the subset of VT100/xterm graff speaks."""

    def __init__(self, cols: int = 80, rows: int = 24):
        self.cols = cols
        self.rows = rows
        self.grid = self._blank_grid(cols, rows)
        self.primary = None  # grid parked while the alt screen (1049) is up
        self.x = 0
        self.y = 0
        self._saved_cursor = (0, 0)
        self.autowrap = True
        self.modes: dict[int, bool] = {}
        self.mode_log: list[tuple[int, bool]] = []
        self.kitty_depth = 0
        self.osc: list[bytes] = []
        self.top = 0
        self.bottom = rows - 1
        self.fg = None
        self.bg = None
        self.inverse = False
        self.bold = False
        self._buf = b""

    # --- grid helpers ---------------------------------------------------
    def _blank_grid(self, cols, rows):
        return [[Cell() for _ in range(cols)] for _ in range(rows)]

    def _blank(self):
        # Erases are background-colour-erase: graff paints a row's theme
        # background by setting SGR 48;2;... and then emitting EL.
        return Cell(" ", None, self.bg, False, False)

    def resize(self, cols: int, rows: int) -> None:
        old, ocols, orows = self.grid, self.cols, self.rows
        self.cols, self.rows = cols, rows
        self.grid = self._blank_grid(cols, rows)
        for y in range(min(orows, rows)):
            for x in range(min(ocols, cols)):
                self.grid[y][x] = old[y][x]
        if self.primary is not None:
            saved = self.primary
            self.primary = self._blank_grid(cols, rows)
            for y in range(min(len(saved), rows)):
                for x in range(min(len(saved[0]), cols)):
                    self.primary[y][x] = saved[y][x]
        self.top, self.bottom = 0, rows - 1
        self.x = min(self.x, cols - 1)
        self.y = min(self.y, rows - 1)

    def line_text(self, y: int) -> str:
        return "".join(c.ch for c in self.grid[y]).rstrip()

    def screen_lines(self) -> list[str]:
        return [self.line_text(y) for y in range(self.rows)]

    def screen_contents(self) -> str:
        return "\n".join(self.screen_lines())

    def cell(self, x: int, y: int) -> Cell:
        return self.grid[y][x]

    def mode_imbalance(self) -> tuple[list[int], int]:
        """(modes whose final state differs from the terminal default, kitty depth)."""
        wrong = sorted(n for n, on in self.modes.items() if on != (n in DEFAULT_ON_MODES))
        return wrong, max(self.kitty_depth, 0)

    # --- cursor / scrolling ---------------------------------------------
    def _index(self):
        if self.y >= self.bottom:
            self.y = self.bottom
            self._scroll_up(1)
        else:
            self.y += 1

    def _scroll_up(self, n):
        for _ in range(n):
            del self.grid[self.top]
            self.grid.insert(self.bottom, [self._blank() for _ in range(self.cols)])

    def _scroll_down(self, n):
        for _ in range(n):
            del self.grid[self.bottom]
            self.grid.insert(self.top, [self._blank() for _ in range(self.cols)])

    def _put(self, ch: str):
        w = char_width(ch)
        if w == 0:
            return
        if self.x >= self.cols:
            if self.autowrap:
                self.x = 0
                self._index()
            else:
                # DEC autowrap off: the cursor pins to the last column and
                # every further glyph overwrites it. graff turns wrap off
                # (?7l) precisely so a full-width row cannot spill.
                self.x = self.cols - 1
        if w == 2 and self.x == self.cols - 1:
            if self.autowrap:
                self.x = 0
                self._index()
            else:
                self.grid[self.y][self.x] = Cell(ch, self.fg, self.bg, self.inverse, self.bold)
                return
        self.grid[self.y][self.x] = Cell(ch, self.fg, self.bg, self.inverse, self.bold)
        if w == 2 and self.x + 1 < self.cols:
            self.grid[self.y][self.x + 1] = Cell("", self.fg, self.bg, self.inverse, self.bold)
        self.x += w

    # --- feed / parse ----------------------------------------------------
    def feed(self, data: bytes) -> None:
        buf = self._buf + data
        i, n = 0, len(buf)
        while i < n:
            b = buf[i]
            if b == 0x1B:
                step = self._escape(buf, i, n)
                if step is None:
                    break  # incomplete sequence: keep it for the next chunk
                i = step
                continue
            if b < 0x20 or b == 0x7F:
                self._control(b)
                i += 1
                continue
            j = i
            while j < n and buf[j] >= 0x20 and buf[j] != 0x7F:
                j += 1
            run = buf[i:j]
            if j == n:
                hold = _incomplete_utf8_tail(run)
                if hold:
                    run = run[:-hold]
                    j -= hold
                    if not run:
                        break
            for ch in run.decode("utf-8", errors="replace"):
                self._put(ch)
            i = j
        self._buf = buf[i:]

    def _control(self, b):
        if b == 0x0D:
            self.x = 0
        elif b == 0x0A or b == 0x0B or b == 0x0C:
            self._index()
        elif b == 0x08:
            self.x = max(0, self.x - 1)
        elif b == 0x09:
            self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)

    def _escape(self, buf, i, n):
        """Handle the escape at `buf[i]`; return the next index, or None if incomplete."""
        if i + 1 >= n:
            return None
        c = buf[i + 1]
        if c == 0x5B:  # CSI
            m = CSI_RE.match(buf, i)
            if m:
                self._csi(m.group(1), m.group(3))
                return m.end()
            if all(x in _PARAM_OR_INTER for x in buf[i + 2 : n]):
                return None  # still arriving
            return i + 1  # malformed: drop the ESC, keep the rest
        if c == 0x5D:  # OSC ... BEL | ST
            end = self._string_end(buf, i + 2, n, bel_ok=True)
            if end is None:
                return None
            self.osc.append(bytes(buf[i + 2 : end[0]]))
            return end[1]
        if c in (0x50, 0x5F, 0x5E, 0x58):  # DCS / APC / PM / SOS (kitty graphics)
            end = self._string_end(buf, i + 2, n, bel_ok=True)
            return None if end is None else end[1]
        if c in (0x28, 0x29, 0x2A, 0x2B, 0x25):  # charset designators
            return None if i + 2 >= n else i + 3
        if c == 0x37:  # DECSC
            self._saved_cursor = (self.x, self.y)
            return i + 2
        if c == 0x38:  # DECRC
            self.x, self.y = self._saved_cursor
            return i + 2
        if c in (0x44, 0x45):  # IND, NEL
            if c == 0x45:
                self.x = 0
            self._index()
            return i + 2
        if c == 0x4D:  # RI
            if self.y <= self.top:
                self._scroll_down(1)
            else:
                self.y -= 1
            return i + 2
        return i + 2  # ESC c, ESC =, ESC >, stray ST: consumed, no grid effect

    @staticmethod
    def _string_end(buf, start, n, bel_ok):
        """(payload_end, next_index) for a string sequence, or None if unterminated."""
        i = start
        while i < n:
            if bel_ok and buf[i] == 0x07:
                return i, i + 1
            if buf[i] == 0x1B:
                if i + 1 >= n:
                    return None
                if buf[i + 1] == 0x5C:
                    return i, i + 2
            i += 1
        return None

    def _csi(self, params: bytes, final: bytes):
        priv = params[:1] in (b"?", b"<", b">", b"=") and params[:1] or b""
        nums = self._nums(params[len(priv) :])
        f = final.decode()
        if priv == b"?":
            if f in ("h", "l"):
                self._private_modes(nums, f == "h")
            return
        if priv in (b"<", b">"):
            # Kitty keyboard protocol push/pop, and xterm modifyOtherKeys.
            if f == "u":
                self.kitty_depth += 1 if priv == b">" else -1
            return
        if priv:
            return
        n0 = nums[0] if nums else 0
        cnt = max(1, n0)
        if f == "H" or f == "f":
            self.y = min(self.rows - 1, max(0, (nums[0] if nums else 1) - 1))
            self.x = min(self.cols - 1, max(0, (nums[1] if len(nums) > 1 else 1) - 1))
        elif f == "A":
            self.y = max(0, self.y - cnt)
        elif f == "B":
            self.y = min(self.rows - 1, self.y + cnt)
        elif f == "C":
            self.x = min(self.cols - 1, self.x + cnt)
        elif f == "D":
            self.x = max(0, self.x - cnt)
        elif f == "G" or f == "`":
            self.x = min(self.cols - 1, max(0, (nums[0] if nums else 1) - 1))
        elif f == "d":
            self.y = min(self.rows - 1, max(0, (nums[0] if nums else 1) - 1))
        elif f == "E":
            self.x = 0
            self.y = min(self.rows - 1, self.y + cnt)
        elif f == "F":
            self.x = 0
            self.y = max(0, self.y - cnt)
        elif f == "J":
            self._erase_display(n0)
        elif f == "K":
            self._erase_line(n0)
        elif f == "X":
            row = self.grid[self.y]
            for x in range(self.x, min(self.cols, self.x + cnt)):
                row[x] = self._blank()
        elif f == "@":
            row = self.grid[self.y]
            for _ in range(cnt):
                row.insert(self.x, self._blank())
            del row[self.cols :]
        elif f == "P":
            row = self.grid[self.y]
            for _ in range(cnt):
                if self.x < len(row):
                    del row[self.x]
                    row.append(self._blank())
        elif f == "L":
            for _ in range(cnt):
                del self.grid[self.bottom]
                self.grid.insert(self.y, [self._blank() for _ in range(self.cols)])
        elif f == "M":
            for _ in range(cnt):
                del self.grid[self.y]
                self.grid.insert(self.bottom, [self._blank() for _ in range(self.cols)])
        elif f == "S":
            self._scroll_up(cnt)
        elif f == "T":
            self._scroll_down(cnt)
        elif f == "r":
            self.top = max(0, (nums[0] if nums else 1) - 1)
            self.bottom = min(self.rows - 1, (nums[1] if len(nums) > 1 else self.rows) - 1)
            self.x, self.y = 0, self.top
        elif f == "m":
            self._sgr(nums)
        elif f == "s":
            self._saved_cursor = (self.x, self.y)
        elif f == "u":
            self.x, self.y = self._saved_cursor

    @staticmethod
    def _nums(params: bytes) -> list[int]:
        out = []
        for part in params.split(b";"):
            try:
                out.append(int(part) if part else 0)
            except ValueError:
                out.append(0)
        return out if params else []

    def _erase_display(self, mode):
        if mode == 2 or mode == 3:
            self.grid = [[self._blank() for _ in range(self.cols)] for _ in range(self.rows)]
            return
        if mode == 0:
            self._erase_line(0)
            for y in range(self.y + 1, self.rows):
                self.grid[y] = [self._blank() for _ in range(self.cols)]
        elif mode == 1:
            self._erase_line(1)
            for y in range(0, self.y):
                self.grid[y] = [self._blank() for _ in range(self.cols)]

    def _erase_line(self, mode):
        row = self.grid[self.y]
        if mode == 1:
            rng = range(0, min(self.x + 1, self.cols))
        elif mode == 2:
            rng = range(0, self.cols)
        else:
            rng = range(min(self.x, self.cols), self.cols)
        for x in rng:
            row[x] = self._blank()

    def _private_modes(self, nums, on):
        for num in nums:
            self.modes[num] = on
            self.mode_log.append((num, on))
            if num == 7:
                self.autowrap = on
            elif num in (1047, 1049):
                self._alt_screen(on)

    def _alt_screen(self, on):
        if on:
            if self.primary is None:
                self.primary = self.grid
                self._saved_cursor = (self.x, self.y)
                self.grid = self._blank_grid(self.cols, self.rows)
                self.x = self.y = 0
        elif self.primary is not None:
            self.grid = self.primary
            self.primary = None
            self.x, self.y = self._saved_cursor
            self.x = min(self.x, self.cols - 1)
            self.y = min(self.y, self.rows - 1)

    def _sgr(self, nums):
        if not nums:
            nums = [0]
        i = 0
        while i < len(nums):
            n = nums[i]
            if n == 0:
                self.fg = self.bg = None
                self.inverse = self.bold = False
            elif n == 1:
                self.bold = True
            elif n in (21, 22):
                self.bold = False
            elif n == 7:
                self.inverse = True
            elif n == 27:
                self.inverse = False
            elif 30 <= n <= 37:
                self.fg = n - 30
            elif 90 <= n <= 97:
                self.fg = n - 90 + 8
            elif n == 39:
                self.fg = None
            elif 40 <= n <= 47:
                self.bg = n - 40
            elif 100 <= n <= 107:
                self.bg = n - 100 + 8
            elif n == 49:
                self.bg = None
            elif n in (38, 48):
                kind = nums[i + 1] if i + 1 < len(nums) else 0
                if kind == 5:
                    val = nums[i + 2] if i + 2 < len(nums) else 0
                    i += 2
                elif kind == 2:
                    val = tuple(nums[i + 2 : i + 5])
                    i += 4
                else:
                    val = None
                    i += 1
                if n == 38:
                    self.fg = val
                else:
                    self.bg = val
            i += 1


class PtyHarness:
    """A child on a pty, its output rendered into a `Screen`.

    Every read is select-gated: a quiet pty blocks, and a blocking read would
    hang the test on exactly the wedged states these tests exist to catch.
    """

    def __init__(self, cmd, cols: int = 100, rows: int = 30, cwd=None, env=None, term="xterm-256color"):
        argv = [cmd] if isinstance(cmd, str) else list(cmd)
        # Absolutized BEFORE the fork: the child chdirs into its scratch
        # workspace, so a relative binary path resolved there is a silent boot
        # failure, not a finding.
        if os.sep in argv[0]:
            argv[0] = os.path.abspath(argv[0])
        self.argv = argv
        self.cols, self.rows = cols, rows
        self.screen = Screen(cols, rows)
        self.raw = bytearray()
        self.exit_status: int | None = None
        self._closed = False

        child_env = os.environ.copy()
        child_env.setdefault("TERM", term)
        if env:
            # A None value UNSETS. A probe that needs a clean slate (no
            # inherited GRAFF_*/CODEX_* from the developer's shell) cannot get
            # there by setting the variable to "" — an empty string is a value,
            # and graff reads several of them as one.
            for k, v in env.items():
                if v is None:
                    child_env.pop(k, None)
                else:
                    child_env[k] = v
        cwd = os.path.abspath(cwd or os.getcwd())
        child_env["PWD"] = cwd

        # openpty (not pty.fork) so the PARENT keeps the slave fd: feed_screen
        # writes to it, and those bytes land on the screen without the child
        # ever seeing them.
        self.master, self.slave = pty.openpty()
        self._winsize(cols, rows)
        self.pid = os.fork()
        if self.pid == 0:
            try:
                os.setsid()
                try:
                    fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
                except OSError:
                    pass
                os.dup2(self.slave, 0)
                os.dup2(self.slave, 1)
                os.dup2(self.slave, 2)
                if self.slave > 2:
                    os.close(self.slave)
                os.close(self.master)
                os.chdir(cwd)
                os.execve(argv[0], argv, child_env)
            except BaseException:
                os._exit(127)

    # --- process ---------------------------------------------------------
    def _winsize(self, cols, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def poll(self):
        if self.exit_status is not None:
            return self.exit_status
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            return self.exit_status
        if pid:
            self.exit_status = status
        return self.exit_status

    def alive(self) -> bool:
        return self.poll() is None

    # --- io --------------------------------------------------------------
    def pump(self, seconds: float = 0.2) -> bytes:
        got = b""
        end = time.time() + max(0.0, seconds)
        while True:
            left = end - time.time()
            if left <= 0:
                break
            r, _, _ = select.select([self.master], [], [], min(0.05, max(left, 0.005)))
            if not r:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            got += chunk
        if got:
            self.raw.extend(got)
            self.screen.feed(got)
        return got

    def inject_keys(self, data) -> None:
        """Send bytes to the CHILD as keystrokes (pty master -> child stdin)."""
        if isinstance(data, str):
            data = KEYS.get(data.lower(), data.encode())
        os.write(self.master, data)

    def feed_screen(self, data: bytes) -> None:
        """Write bytes STRAIGHT to the tty, bypassing the child.

        This is what a tmux status repaint, an nvim redraw, or another process
        writing to the same terminal does to graff's frame. The bytes reach the
        screen (and our grid) exactly as if graff had emitted them, while graff
        itself has no idea its frame was overwritten.
        """
        os.write(self.slave, data)
        deadline = time.time() + 1.0
        before = len(self.raw)
        while time.time() < deadline and len(self.raw) - before < len(data):
            if not self.pump(0.1):
                continue

    def resize(self, cols: int, rows: int) -> None:
        self.cols, self.rows = cols, rows
        self._winsize(cols, rows)
        self.screen.resize(cols, rows)

    # --- assertions ------------------------------------------------------
    def screen_contents(self) -> str:
        return self.screen.screen_contents()

    def screen_lines(self) -> list[str]:
        return self.screen.screen_lines()

    def cell(self, x: int, y: int) -> Cell:
        return self.screen.cell(x, y)

    def mode_imbalance(self):
        return self.screen.mode_imbalance()

    @property
    def modes(self):
        return self.screen.modes

    def wait_for_text(self, text: str, timeout: float = 10.0, settle: float = 0.0) -> bool:
        end = time.time() + timeout
        while time.time() < end:
            if text in self.screen_contents():
                if settle:
                    self.pump(settle)
                return True
            if not self.pump(0.1) and self.poll() is not None:
                break
        if text in self.screen_contents():
            return True
        raise PtyTimeout(f"never saw {text!r} on screen\n--- screen ---\n{self.screen_contents()}")

    def wait_for_boot(self, timeout: float = 15.0, settle: float = 1.0) -> bool:
        """Readiness, not a fixed sleep: the alt-screen enter proves the TUI is up."""
        end = time.time() + timeout
        while time.time() < end:
            if self.screen.modes.get(1049):
                self.pump(settle)
                return True
            self.pump(0.2)
        return bool(self.screen.modes.get(1049))

    # --- teardown --------------------------------------------------------
    def quit(self, wait: float = 4.0):
        """Escalating quit, ported from tui-pty-guard.py: Ctrl+Q, then
        Escape+Ctrl+Q (a toast or composer text occasionally swallows the first
        under load), then double Ctrl+C. Keeps pumping so the restore tail is
        interpreted — the mode bookkeeping depends on it."""
        for attempt in (b"\x11", b"\x1b\x1b\x11", b"\x03\x03"):
            if self.poll() is not None:
                break
            try:
                os.write(self.master, attempt)
            except OSError:
                break
            self.pump(wait)
            end = time.time() + 2.0
            while time.time() < end:
                if self.poll() is not None:
                    break
                self.pump(0.1)
            if self.poll() is not None:
                break
        if self.poll() is None:
            os.kill(self.pid, signal.SIGKILL)
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
            self.exit_status = None
            return None
        self.pump(0.3)  # the restore tail can land after the exit is reaped
        return self.exit_status

    def kill(self, sig=signal.SIGTERM, drain: float = 3.0):
        try:
            os.kill(self.pid, sig)
        except ProcessLookupError:
            return
        self.pump(drain)
        end = time.time() + 3.0
        while time.time() < end and self.poll() is None:
            self.pump(0.1)
        if self.poll() is None:
            os.kill(self.pid, signal.SIGKILL)
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass

    def close(self) -> None:
        if self._closed:
            return
        if self.poll() is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except OSError:
                pass
            except ChildProcessError:
                pass
        for fd in (self.master, self.slave):
            try:
                os.close(fd)
            except OSError:
                pass
        self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def _selftest(verbose: bool = False) -> int:
    """Interpreter regression, no pty and no binary needed."""
    fails = []

    def check(name, cond, extra=""):
        if cond:
            if verbose:
                print(f"  ✓ {name}")
        else:
            fails.append(name)
            print(f"  ✗ {name} {extra}")

    s = Screen(10, 4)
    s.feed(b"hello")
    check("printable run lands on row 0", s.line_text(0) == "hello", s.line_text(0))
    s.feed(b"\x1b[2;3Hx")
    check("CUP addresses 1-based row;col", s.cell(2, 1).ch == "x")
    s.feed(b"\x1b[1;1H\x1b[K")
    check("EL 0 erases to end of line", s.line_text(0) == "")
    s.feed(b"\x1b[2J")
    check("ED 2 clears the screen", s.screen_contents().strip() == "")

    s = Screen(5, 2)
    s.feed(b"\x1b[?7l" + b"ABCDEFGH")
    check("autowrap off pins to the last column", s.line_text(0) == "ABCDH" and s.line_text(1) == "",
          repr(s.screen_lines()))
    s = Screen(5, 2)
    s.feed(b"ABCDEFGH")
    check("autowrap on wraps to the next row", s.line_text(0) == "ABCDE" and s.line_text(1) == "FGH")

    s = Screen(8, 2)
    s.feed(b"\x1b[7mINV\x1b[27mOK")
    check("SGR 7/27 tracked per cell", s.cell(0, 0).inverse and not s.cell(3, 0).inverse)
    s.feed(b"\x1b[1;1H\x1b[48;2;20;20;20m\x1b[K")
    check("erase is background-colour-erase", s.cell(4, 0).bg == (20, 20, 20), repr(s.cell(4, 0)))

    s = Screen(8, 2)
    s.feed(b"\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m")
    latched, depth = s.mode_imbalance()
    check("enable string latches every mode", latched == [7, 25, 1000, 1003, 1006, 1049, 2004], repr(latched))
    check("kitty push counted", depth == 1)
    s.feed(b"\x1b[?2026l\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l")
    latched, depth = s.mode_imbalance()
    check("restore string balances every mode", latched == [] and depth == 0, f"{latched} depth={depth}")

    s = Screen(8, 2)
    s.feed(b"ab\x1b]11;rgb:1a/1a/1a\x07cd")
    check("OSC swallowed, not printed", s.line_text(0) == "abcd", s.line_text(0))
    s.feed(b"\x1b[1;1H\x1b[2K\x1b_Ga=d,d=A,q=2\x1b\\zz")
    check("APC (kitty graphics) swallowed", s.line_text(0) == "zz", s.line_text(0))

    s = Screen(8, 2)
    s.feed(b"ab\x1b[")  # split mid-CSI
    s.feed(b"1;1Hxy")
    check("a CSI split across feeds still parses", s.line_text(0) == "xy", s.line_text(0))
    s = Screen(8, 2)
    s.feed(b"\xe2\x94")  # split mid-UTF-8
    s.feed(b"\x80")
    check("a UTF-8 char split across feeds still decodes", s.line_text(0) == "─", repr(s.line_text(0)))

    s = Screen(6, 2)
    s.feed("你好".encode("utf-8"))
    check("wide chars take two cells", s.cell(0, 0).ch == "你" and s.cell(1, 0).ch == "")

    s = Screen(6, 3)
    s.feed(b"a\r\nb\r\nc\r\nd")
    check("LF at the bottom scrolls", s.screen_lines() == ["b", "c", "d"], repr(s.screen_lines()))

    s = Screen(6, 2)
    s.feed(b"hello")
    s.resize(3, 2)
    check("resize keeps the top-left content", s.line_text(0) == "hel", s.line_text(0))

    if fails:
        print(f"ptyharness selftest: FAIL ({len(fails)} failing)")
    elif verbose:
        print("ptyharness selftest: ok")
    return 1 if fails else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest(verbose=True))
    print(__doc__)
