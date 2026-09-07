#!/usr/bin/env python3
"""Live proof: a horizontal resize must not move the transcript under the user.

grok-build holds a LOGICAL scroll anchor across a width rebuild — the entry the
top visible line belongs to, plus that line's ordinal inside the entry — so a
rewrap puts the same content back on top instead of the same ROW NUMBER. This
probe drives the real binary under a pty and proves it end to end:

  1. boots `graff tui --yolo` in a scratch cwd with an EMPTY MCP config,
  2. fills the transcript from `!printf` lines only (no model call, so the text
     on screen is known exactly), with one unique marker in the middle,
  3. vertical sweep FIRST, while the user is tailing: the transcript must keep
     following the bottom, so the last line stays on screen at every height,
  4. scrolls up (Ctrl+K) until the marker sits near the top of the viewport,
  5. drives TIOCSWINSZ across five widths and asserts the marker is still on
     screen and has barely moved. Without an anchor, `scroll` is a distance
     from the bottom of a transcript whose row count just changed, so the
     marker slides away and off screen.

Usage: python3 scripts/test-tui-resize-anchor.py [path/to/graff]
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
# Printed through a printf FORMAT so the echoed command line never contains the
# marker itself — otherwise the sticky header (which pins the last prompt) would
# satisfy "the marker is on screen" without the transcript being anywhere near.
MARK = "ANCHORMARKKILO"
MARK_CMD = r"!printf 'ANCHOR%sKILO\n' MARK"
TAIL = "TAILROWOMEGA"
# Rewrapping the entries above the anchor can only shift a near-top line by the
# few rows those entries themselves gain or lose; the failure this guards
# against moves it by tens of rows or off screen entirely.
DRIFT = 4


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
    ws = tempfile.mkdtemp(prefix="tui-anchor-")
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


def stable_frame(fd, rows, cols, budget=1.5):
    # #750: a width change can emit two full frames (old wrap, then anchored).
    # The first parse is a real frame — it just is not the settled one — so
    # the parallel suite saw a marker jump. Wait for two identical parses
    # inside the original settle budget. Do not relax DRIFT.
    resize(fd, rows, cols)
    last = None
    deadline = time.time() + budget
    while time.time() < deadline:
        now = parse(drain(fd, 0.12))
        if now is None:
            continue
        if last is not None and now == last:
            return now
        last = now
    return last


def reread(fd):
    """A full frame at the current width, via a HEIGHT-only jiggle.

    Vertical resizes never take the anchor path, so reading the screen this way
    cannot itself perturb what the width sweep is about to measure.
    """
    resize(fd, ROWS - 1, COLS)
    drain(fd, 0.4)
    return frame_at(fd, ROWS, COLS)


def find(rows, needle):
    # The sticky header pins the last user prompt at the top of the viewport;
    # a hit there is chrome, not the transcript.
    for i, ln in enumerate(rows or []):
        if needle in ln and "❯" not in ln:
            return i
    return None


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    try:
        boot(fd)
        # Transcript content with no model call: `!` lines run in-session. Long
        # lines so every width below genuinely rewraps them.
        def block(tag):
            body = "filler line %s-%d padded out so that it rewraps at every width this probe drives"
            lines = "".join((body % (tag, k)) + r"\n" for k in range(3))
            os.write(fd, (r"!printf '" + lines + r"'" + "\r").encode())
            drain(fd, 1.5)

        for i in range(3):
            block(f"A{i}")
        os.write(fd, (MARK_CMD + "\r").encode())
        drain(fd, 1.5)
        # Enough transcript AFTER the marker that it starts off the top of the
        # viewport: the parking loop below then walks it in from the top edge,
        # which is the only way to put it near the anchored row from outside.
        for i in range(5):
            block(f"B{i}")
        os.write(fd, (r"!printf '" + TAIL + r"\n'" + "\r").encode())
        out = drain(fd, 2.5)
        if TAIL.encode() not in out:
            return "the transcript never showed the tail row (no `!` output)"

        # --- vertical only, while tailing: bottom-follow must hold -----------
        # Every step must CHANGE the height: an identical winsize is not a
        # resize, so no full repaint follows it and there is nothing to read.
        for h in (18, 34, 22, ROWS):
            rows = stable_frame(fd, h, COLS)
            if rows is None:
                return f"no full repaint at height {h}"
            if find(rows, TAIL) is None:
                return f"a vertical resize to {h} rows dropped the tail row: follow broke"

        # --- park the marker near the top of the viewport ---------------------
        top = None
        for _ in range(30):
            os.write(fd, b"\x0b")  # Ctrl+K: scroll one line towards older text
            drain(fd, 0.25)
            at = find(reread(fd), MARK)
            if at is not None:
                # It has just cleared the top edge. Two more lines put it clear
                # of the sticky header, which OCCLUDES the top two content rows
                # — a marker parked under the pin is invisible, not misplaced.
                os.write(fd, b"\x0b\x0b")
                drain(fd, 0.3)
                top = find(reread(fd), MARK)
                break
        if top is None:
            return f"scrolling never brought {MARK} into the upper viewport"

        # --- the width sweep --------------------------------------------------
        seen = [(COLS, top)]
        for w in (76, 58, 44, 92, COLS):
            rows = stable_frame(fd, ROWS, w)
            if rows is None:
                return f"no full repaint at width {w}"
            at = find(rows, MARK)
            if at is None:
                return f"width {w} scrolled {MARK} off screen (anchor lost); seen={seen}"
            if abs(at - top) > DRIFT:
                again = stable_frame(fd, ROWS, w, budget=1.8)
                at2 = find(again, MARK) if again else None
                if at2 is None or abs(at2 - top) > DRIFT:
                    return f"width {w} moved {MARK} from row {top} to {at2 if at2 is not None else at}; seen={seen}"
                at = at2
            seen.append((w, at))
        print(f"    widths/rows: {seen}")
        return None
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-resize-anchor: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-resize-anchor: no pty support here — skipping")
        return 0
    err = run()
    if err:
        print(f"  ✗ resize-anchor: {err}")
        return 1
    print("  ✓ resize-anchor: the marker held its place across five widths")
    return 0


if __name__ == "__main__":
    sys.exit(main())
