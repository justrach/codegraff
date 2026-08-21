#!/usr/bin/env python3
"""Live proof: scrolling is a viewport SLICE of one layout, not a re-layout.

TUI/layout_cache.zig keeps every history entry's wrapped display lines and a
prefix sum of where each block starts in virtual-Y, so a wheel tick is a binary
search plus a screenful of slices. The failure modes a cache introduces are all
visible on screen: a stale block, a line served from the wrong offset, a
duplicated or skipped row after a width change. This probe drives the real
binary under a pty and reads the screen back:

  1. boots `graff tui --yolo` in a scratch cwd with an EMPTY MCP config,
  2. fills the transcript with numbered marker lines printed through a printf
     FORMAT, so the echoed command line never contains a marker itself (the
     sticky header pins the last prompt, and a marker there is chrome),
  3. scrolls up one line at a time and asserts, on every frame, that the
     markers on screen are a CONTIGUOUS ASCENDING run — no gap, no repeat —
     and that the run walks strictly backwards through the transcript,
  4. changes width mid-scroll and asserts the same thing at the new width,
     which is the cold-rebuild path,
  5. reports the wall clock per scroll step for scale.

Usage: python3 scripts/test-tui-layout-cache.py [path/to/graff]
       (default zig-out/bin/graff).  Exit 0 = pass; skips (exit 0) with no pty.
"""
import os
import re
import sys
import tempfile
import time

# Absolutized BEFORE the fork: the child chdirs into its scratch workspace.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 15.0
ROWS, COLS = 30, 100
BLOCKS = 8
PER_BLOCK = 10
MARK = re.compile(r"LC(\d{4})")
STEPS = 20


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
    # A pty forked without a size reports 0x0; the TUI would clamp to its 40x12
    # floor and every row index below would be measured against the wrong frame.
    resize(fd, rows, cols)
    return pid, fd


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-layout-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def reap(pid, fd):
    import signal
    try:
        os.write(fd, b"\x11")  # Ctrl+Q
        drain(fd, 3.0)
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


def parse(stream):
    """Screen rows, in order, out of the last FULL repaint in `stream`.

    Between repaints the TUI rewrites only the rows that changed, addressing
    each with CSI row;1H — stripping those out of a diff stream gives row
    indices that are plausible and wrong. Any resize invalidates run.zig's diff
    baseline, so what follows one is a whole frame, top row first.
    """
    frame = stream.rsplit(b"\x1b[2J\x1b[H", 1)
    if len(frame) < 2:
        return None
    text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", frame[1])
    text = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", text)
    return [ln.decode(errors="replace") for ln in text.split(b"\r\n")]


def frame_at(fd, rows, cols, settle=1.2):
    resize(fd, rows, cols)
    return parse(drain(fd, settle))


def reread(fd, cols=COLS):
    """A full frame at the current width, via a HEIGHT-only jiggle."""
    resize(fd, ROWS - 1, cols)
    drain(fd, 0.4)
    return frame_at(fd, ROWS, cols)


def marks(rows):
    """Marker numbers in screen order, ignoring the sticky-header chrome row."""
    out = []
    for ln in rows or []:
        if "❯" in ln:  # ❯ — the pinned prompt, not the transcript
            continue
        for m in MARK.finditer(ln):
            out.append(int(m.group(1)))
    return out


def contiguous(seq):
    return all(b == a + 1 for a, b in zip(seq, seq[1:]))


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    try:
        boot(fd)
        # Marker lines via a printf FORMAT: the echoed command carries "LC%04d"
        # and bare integers, never a marker, so a hit on screen is transcript.
        # `!cmd` is a single background op: send the next only after this block's
        # last marker has been painted, or the rest bounce as "engine still running".
        for b in range(BLOCKS):
            last = b * PER_BLOCK + PER_BLOCK - 1
            needle = f"LC{last:04d}".encode()
            args = " ".join(str(b * PER_BLOCK + k) for k in range(PER_BLOCK))
            cmd = (
                r"!printf 'LC%04d filler text long enough that it rewraps at "
                r"every width this probe drives\n' " + args
            )
            os.write(fd, (cmd + "\r").encode())
            got = b""
            end = time.time() + 8.0
            while time.time() < end:
                got += drain(fd, 0.3)
                if needle in got:
                    break
            else:
                return f"block {b} never painted LC{last:04d} (no `!` output)"


        total = BLOCKS * PER_BLOCK
        seen = marks(reread(fd))
        if not seen:
            return "the transcript never showed a marker line (no `!` output)"
        if not contiguous(seen):
            return f"the bottom frame is not a contiguous slice: {seen}"
        if seen[-1] != total - 1:
            return f"follow mode is not at the bottom: last marker {seen[-1]} of {total - 1}"

        # --- scroll up one line at a time -----------------------------------
        started = time.time()
        top = seen[0]
        walked = 0
        for step in range(STEPS):
            os.write(fd, b"\x0b")  # Ctrl+K: one line towards older text
            drain(fd, 0.2)
            cur = marks(reread(fd))
            if not cur:
                return f"step {step} showed no markers at all"
            if not contiguous(cur):
                return f"step {step} served a non-contiguous slice: {cur}"
            if cur[0] > top:
                return f"step {step} scrolled the wrong way: {cur[0]} > {top}"
            walked += top - cur[0]
            top = cur[0]
        if walked == 0:
            return "scrolling up never moved the viewport"
        per_step = (time.time() - started) / STEPS

        # --- width change mid-scroll: the cold rebuild ----------------------
        for w in (72, 58, 92, COLS):
            rows = frame_at(fd, ROWS, w)
            if rows is None:
                return f"no full repaint at width {w}"
            cur = marks(rows)
            if not cur:
                return f"width {w} lost the transcript entirely"
            if not contiguous(cur):
                return f"width {w} served a non-contiguous slice: {cur}"

        # --- back to the bottom ---------------------------------------------
        for _ in range(8):
            os.write(fd, b"\x1b[6~")  # PgDn: back towards the live tail
            drain(fd, 0.2)
        drain(fd, 1.0)
        cur = marks(reread(fd))
        if not contiguous(cur) or cur[-1] != total - 1:
            return f"scrolling back down did not return to the tail: {cur}"

        print(
            f"    {total} marker lines, walked {walked} rows up and back, "
            f"{per_step * 1000:.0f} ms per probe step (resize/settle waits, "
            f"not frame time — see scripts/bench-tui-layout.sh for that)"
        )
        return None
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-layout-cache: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-layout-cache: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ layout-cache: {err}")
        return 1
    print("  ✓ layout-cache: every frame was a contiguous slice of one layout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
