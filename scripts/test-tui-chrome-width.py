#!/usr/bin/env python3
"""Live proof that animated chrome is exactly one terminal column.

grok-build's discipline: every animated glyph — spinner frames, status dots,
accent bars, chevrons, selection bars — draws in ONE cell, so the label or timer
beside it never steps sideways while the animation ticks. TUI/glyphs.zig pins
that for the frame sets; this probe pins it for the pixels, against the real
binary under a pty.

  1. boots `graff tui --yolo` in a scratch cwd with an EMPTY MCP config,
  2. starts a long `!sleep` so the PENDING row is live with no model call,
  3. reads the repaints of that one row out of the diff stream,
  4. asserts at least four distinct animation frames went by,
  5. asserts the label kept the SAME column in every one of them,
  6. asserts the animated cell itself is East-Asian-Neutral/Narrow — one column
     in every terminal, including one that draws ambiguous glyphs double-width.

Usage: python3 scripts/test-tui-chrome-width.py [path/to/graff]
Exit 0 = pass. Skips (exit 0, notice) when the binary is absent or there is no
pty here.
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
LABEL = "running"  # the pending label bgop.zig pushes for `!cmd`
ROWS, COLS = 30, 100
WATCH_S = 5.0
MIN_FRAMES = 4


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
    ws = tempfile.mkdtemp(prefix="tui-chrome-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def reap(pid, fd):
    import signal
    try:
        os.write(fd, b"\x1b")  # cancel the background op first
        drain(fd, 0.5)
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


def plain(b):
    """Bytes minus OSC/APC strings and CSI/SGR sequences."""
    s = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", b)
    s = re.sub(rb"\x1b_[^\x1b]*\x1b\\", b"", s)
    s = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", s)
    return s.decode(errors="replace")


def cols_of(s):
    """Terminal columns of `s` — the measure the TUI's own visibleLen models."""
    n = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        n += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return n


def row_repaints(stream):
    """{screen row -> [rendered text, ...]} from run.zig's diff paints.

    Between frames the TUI rewrites only the rows that changed, addressing each
    with CSI row;1H — so a row's animation history is exactly the segments that
    follow its own address.
    """
    out = {}
    parts = re.split(rb"\x1b\[(\d+);1H", stream)
    for i in range(1, len(parts) - 1, 2):
        row = int(parts[i])
        out.setdefault(row, []).append(plain(parts[i + 1]))
    return out


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    try:
        boot(fd)
        # A long shell command: the pending row is live, with a blinking glyph
        # and a static label, and no provider is involved.
        os.write(fd, b"!sleep 20\r")
        started = drain(fd, 2.0)
        if LABEL.encode() not in started:
            return f"the pending row never showed {LABEL!r} (no background op)"
        stream = drain(fd, WATCH_S)
        frames = [
            (row, text)
            for row, texts in row_repaints(stream).items()
            for text in texts
            if LABEL in text
        ]
        if len(frames) < MIN_FRAMES:
            return f"only {len(frames)} repaint(s) of the pending row in {WATCH_S}s — the animation is not ticking"
        rows = {row for row, _ in frames}
        if len(rows) != 1:
            return f"the pending row moved between screen rows {sorted(rows)}"
        cols = set()
        glyphs = set()
        for _, text in frames:
            at = text.index(LABEL)
            cols.add(cols_of(text[:at]))
            gutter = text[:at].strip()
            if len(gutter) != 1:
                return f"the gutter held {gutter!r}, not a single animated glyph"
            glyphs.add(gutter)
        if len(cols) != 1:
            return f"the label sat at columns {sorted(cols)} across {len(frames)} frames — animated chrome is shifting it"
        if len(glyphs) < 2:
            return f"only one distinct frame {glyphs} — the row is static, not animated"
        for g in glyphs:
            if cols_of(g) != 1:
                return f"frame {g!r} draws {cols_of(g)} columns"
            if unicodedata.east_asian_width(g) not in ("N", "Na"):
                return (
                    f"frame {g!r} is East_Asian_Width "
                    f"{unicodedata.east_asian_width(g)} — two columns in an ambiguous-wide terminal"
                )
        print(
            f"  ✓ chrome width: {len(frames)} frames, {sorted(glyphs)} each 1 col, "
            f"label fixed at column {cols.pop()}"
        )
        return None
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-chrome-width: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-chrome-width: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ chrome width: {err}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
