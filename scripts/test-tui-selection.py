#!/usr/bin/env python3
"""Live proof for #529: drag-select in the fullscreen TUI, against the real binary.

Under a pty, with a real session (so the clipboard callback is the session's
own), the probe:

  1. boots `graff tui --yolo` in a scratch cwd with an EMPTY MCP config,
  2. fills the transcript with a shell line (`!printf ...`) so no model call is
     needed and the text on screen is known,
  3. sends an SGR mouse drag over the transcript — press, motions, release,
  4. asserts the frame that comes back carries inverse-video (SGR 7) spans,
  5. asserts the system clipboard now holds the dragged text (pbpaste), and
     that a following keystroke clears the band again.

Usage: python3 scripts/test-tui-selection.py [path/to/graff]  (default zig-out/bin/graff)
Exit 0 = pass. Skips (exit 0, notice) with no pty or no clipboard tool.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

# Absolutized BEFORE the fork: the child chdirs into its scratch workspace.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 15.0
MARK = "SELECTME_ZULU"
SENTINEL = "CLIPBOARD_SENTINEL_BEFORE_DRAG"


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


def spawn(cwd, env_extra, rows=30, cols=100):
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo"])
    # A pty forked without a size reports 0x0; the TUI would clamp to its 40x12
    # floor and the drag rows below would land in the composer.
    resize(fd, rows, cols)
    return pid, fd


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-sel-")
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
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass


def clipboard_set(text):
    subprocess.run(["pbcopy"], input=text.encode(), check=True)


def clipboard_get():
    return subprocess.run(["pbpaste"], capture_output=True, check=True).stdout.decode()


def sgr(btn, col, row, press=True):
    return f"\x1b[<{btn};{col};{row}{'M' if press else 'm'}".encode()


def full_frame(fd, rows, cols):
    """Screen rows, in order, from a FORCED full repaint.

    Between repaints the TUI only rewrites the rows that changed, addressing
    each with CSI row;1H — stripping those out of a diff stream gives row
    indices that are plausible and wrong. A resize invalidates run.zig's diff
    baseline, so what follows is one whole frame, top row first.
    """
    resize(fd, rows - 1, cols)
    drain(fd, 0.4)
    resize(fd, rows, cols)
    stream = drain(fd, 1.2)
    frame = stream.rsplit(b"\x1b[2J\x1b[H", 1)
    if len(frame) < 2:
        return None
    text = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", frame[1])
    text = re.sub(rb"\x1b\[[0-9;?<>]*[a-zA-Z]", b"", text)
    return [ln.decode(errors="replace") for ln in text.split(b"\r\n")]


ROWS, COLS = 30, 100


def run():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env, ROWS, COLS)
    try:
        boot(fd)
        # Transcript content without a model call: the `!` line runs in-session.
        os.write(fd, f"!printf '{MARK}_ONE\\n{MARK}_TWO\\n'\r".encode())
        out = drain(fd, 4.0)
        if MARK.encode() not in out:
            return f"the transcript never showed {MARK} (bash row missing)"
        rows = full_frame(fd, ROWS, COLS)
        if rows is None:
            return "no full repaint to read the screen from"
        hit = next((i for i, ln in enumerate(rows) if MARK + "_ONE" in ln), None)
        if hit is None:
            return f"{MARK}_ONE is not on any screen row of the full frame"
        # Baseline: nothing is inverse-video before the drag.
        idle = drain(fd, 0.4)
        if b"\x1b[7m" in idle:
            return "the idle frame already carries an inverse-video band"
        clipboard_set(SENTINEL)
        # Press on the marked row, drag two rows down, release. SGR: button 0
        # press, 32 = motion with the button held, final 'm' = release.
        top = hit + 1  # screen rows are 1-based in the SGR report
        os.write(fd, sgr(0, 3, top))
        drain(fd, 0.3)
        os.write(fd, sgr(32, 40, top + 1))
        drain(fd, 0.3)
        os.write(fd, sgr(32, 60, top + 2))
        painted = drain(fd, 0.6)
        if b"\x1b[7m" not in painted:
            return "the drag painted no inverse-video band (no SGR 7 in the frame)"
        if b"\x1b[27m" not in painted:
            return "the band never emitted its SGR 27 terminator"
        os.write(fd, sgr(0, 60, top + 2, press=False))
        drain(fd, 1.0)
        got = clipboard_get()
        if got == SENTINEL:
            return "the release did not reach the clipboard (still the sentinel)"
        if f"{MARK}_ONE" not in got:
            return f"the clipboard got {got!r}, which does not contain {MARK}_ONE"
        if len(got.split("\n")) != 3:
            return f"a 3-row drag copied {len(got.split(chr(10)))} row(s): {got!r}"
        # A following keystroke drops the band: the repaint that follows must
        # rewrite those rows WITHOUT inverse video.
        os.write(fd, b"z")
        after = drain(fd, 1.0)
        if b"\x1b[7m" in after:
            return "a keystroke did not clear the band"
        return None
    finally:
        reap(pid, fd)


def main():
    if not os.path.exists(BIN):
        print(f"tui-selection: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-selection: no pty support here — skipping")
        return 0
    if sys.platform != "darwin":
        print("tui-selection: clipboard probe is macOS-only (pbcopy/pbpaste) — skipping")
        return 0
    saved = None
    try:
        saved = clipboard_get()
    except Exception:
        print("tui-selection: no clipboard access — skipping")
        return 0
    try:
        err = run()
    finally:
        if saved is not None:
            try:
                clipboard_set(saved)
            except Exception:
                pass
    if err:
        print(f"  ✗ drag-select: {err}")
        return 1
    print("  ✓ drag-select: inverse band painted, clipboard received the rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
