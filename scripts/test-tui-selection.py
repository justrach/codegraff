#!/usr/bin/env python3
"""Live proof for #529: drag-select in the fullscreen TUI, against the real binary.

Under a pty, with a real session (so the clipboard callback is the session's
own), the probe:

  1. boots `graff tui --yolo` in a scratch cwd with an EMPTY MCP config,
  2. fills the transcript with a shell line (`!printf ...`) so no model call is
     needed and the text on screen is known,
  3. sends an SGR mouse drag over the transcript — press, motions, release,
  4. asserts the frame that comes back carries inverse-video (SGR 7) spans,
  5. asserts the system clipboard now holds exactly the dragged text (pbpaste),
  6. asserts the CAPTURE CONTRACT against the live screen: a drag that runs off
     the last text row and down through the blank screen below the transcript
     copies the same thing the tight drag did, and a drag that covers nothing
     but blank rows leaves a pre-seeded clipboard sentinel untouched, and
  7. asserts a following keystroke clears the band again.

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
# Returned instead of an error when the environment, not the TUI, is at fault.
SKIP = "skip: the clipboard is being written by another app"


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


def clipboard_after_copy(prev, tries=10):
    """The clipboard once a copy has landed. pbpaste can observe the pasteboard
    mid-write and come back empty, which would read as "copied nothing"."""
    got = prev
    for _ in range(tries):
        got = clipboard_get()
        if got and got != prev:
            return got
        time.sleep(0.2)
    return got


def seed_clipboard():
    """Plant the sentinel and confirm it stuck. A clipboard manager writing in
    the background must read as a skip, never as a failure of the TUI."""
    for _ in range(3):
        clipboard_set(SENTINEL)
        if clipboard_get() == SENTINEL:
            return True
    return False


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


def drag_copy(fd, r0, r1):
    """Press on row r0, drag through r1, release. Rows are 1-based, as SGR reports.

    Returns (painted, after) — the stream while the button was down, and the
    stream after the release, which is where the copy toast shows up.
    """
    os.write(fd, sgr(0, 1, r0))
    drain(fd, 0.3)
    os.write(fd, sgr(32, COLS, (r0 + r1) // 2))
    drain(fd, 0.2)
    os.write(fd, sgr(32, COLS, r1))
    painted = drain(fd, 0.6)
    os.write(fd, sgr(0, COLS, r1, press=False))
    return painted, drain(fd, 1.0)


def blank_run(rows, start):
    """The contiguous run of blank screen rows at `start` — the empty screen
    below the transcript, which a drag must be able to overshoot into."""
    out = []
    i = start
    while i < len(rows) and rows[i].strip() == "":
        out.append(i)
        i += 1
    return out


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
        # `hit` is the ECHOED command line — it carries the mark inside the
        # printf argument. The output block is the rows after it, up to the last
        # row still carrying the mark; the echo row is skipped because the TUI
        # decorates it with a run marker that changes between frames.
        first, last = hit + 1, max(i for i, ln in enumerate(rows) if MARK in ln)
        if last <= first:
            return "the printf output did not land on its own screen rows"
        blanks = blank_run(rows, last + 1)
        if len(blanks) < 4:
            return "no blank screen region below the transcript to drag into"
        if not seed_clipboard():
            return SKIP
        # A TIGHT drag: press on the marked row, release on the last text row.
        # SGR: button 0 press, 32 = motion with the button held, final 'm'.
        top = first + 1  # screen rows are 1-based in the SGR report
        painted, _ = drag_copy(fd, top, last + 1)
        if b"\x1b[7m" not in painted:
            return "the drag painted no inverse-video band (no SGR 7 in the frame)"
        if b"\x1b[27m" not in painted:
            return "the band never emitted its SGR 27 terminator"
        tight = clipboard_after_copy(SENTINEL)
        if tight == SENTINEL:
            return "the release did not reach the clipboard (still the sentinel)"
        # Row bytes are asserted by shape, not compared to the pre-drag frame:
        # the press moves scrollback focus, which puts a `›` marker in column 0
        # of the pressed row. That marker is real screen text and is copied.
        lines = tight.split("\n")
        if len(lines) != last - first + 1:
            return f"a {last - first + 1}-text-row drag copied {len(lines)} line(s): {tight!r}"
        if not lines[0].endswith(f"{MARK}_ONE") or not lines[-1].endswith(f"{MARK}_TWO"):
            return f"the tight drag copied {tight!r}, not the two marked rows"
        if any(ln.strip() == "" for ln in lines):
            return f"the tight drag copied a blank line: {tight!r}"
        if any(ln != ln.rstrip() for ln in lines):
            return f"a copied row kept its trailing padding: {tight!r}"
        # OVERSHOOT: the same first row, released far down in the blank screen
        # below the transcript. Blank rows are padding, not content, so this
        # must land exactly what the tight drag did — no trailing empty lines.
        if not seed_clipboard():
            return SKIP
        drag_copy(fd, top, blanks[-1] + 1)  # release deep in the blank screen
        loose = clipboard_after_copy(SENTINEL)
        if loose != tight:
            return f"overshooting into the blank screen copied {loose!r}, wanted {tight!r}"
        # BLANK-ONLY: a drag wholly inside the empty screen copies nothing at
        # all — the clipboard keeps what the user had, and no toast claims a copy.
        drain(fd, 2.0)  # let the previous copy toast expire first
        if not seed_clipboard():
            return SKIP
        _, after_blank = drag_copy(fd, blanks[1] + 1, blanks[-2] + 1)
        empty = clipboard_get()
        if empty != SENTINEL:
            return f"a drag over blank rows overwrote the clipboard with {empty!r}"
        if b"copied" in after_blank:
            return "a drag over blank rows still showed a 'copied' toast"
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
    if err == SKIP:
        print(f"tui-selection: {err[6:]} — skipping")
        return 0
    if err:
        print(f"  ✗ drag-select: {err}")
        return 1
    print("  ✓ drag-select: band painted, clipboard got the text rows and only those")
    return 0


if __name__ == "__main__":
    sys.exit(main())
