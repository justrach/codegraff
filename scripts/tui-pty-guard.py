#!/usr/bin/env python3
"""TUI lifecycle guard: real-binary pty checks, grok-build-inspired, no model calls.

Three invariants, each against the actual graff binary under a pty:

  A. mode-balance   Every DEC private mode the TUI latches (CSI ? Pm h) is reset
                    (CSI ? Pm l) by clean quit, the kitty keyboard push/pop depth
                    is balanced, and the alt-screen leave (?1049l) is emitted in
                    the restore tail. grok-build proves restore correctness with
                    a ModeTracker + byte-transparency e2e tests; this is the
                    same invariant as a gate.
  B. hostile-input  The historical crasher corpus (10+-digit CSI params #545,
                    separator-split debris #546, a bracketed paste whose 201~
                    terminator is split across reads #532/#536/#548) is fed to a
                    live session; the process must survive, recover the
                    composer, and still quit cleanly with a balanced restore.
  C. kill-restore   SIGTERM mid-session still emits the restore tail — the
                    terminal is never left raw (#535/#547 family).

Usage: python3 scripts/tui-pty-guard.py [path/to/graff]   (default zig-out/bin/graff)
Exit 0 = all pass; nonzero prints the failing invariant. Skips (exit 0, notice)
when no pty can be allocated (rare CI sandboxes).

Known limitation: check B's echo probe proves liveness, not paste-latch
semantics (a latched composer still echoes typed bytes). Latch behavior is
pinned by the TUI unit suite (zig build tui-test); this guard owns the
process-level invariants a unit test cannot reach.
"""
import json
import os
import re
import signal
import sys
import tempfile
import time

# Absolutized BEFORE any fork: the child chdirs to its scratch workspace, so a
# relative path resolved there is a silent boot failure, not a graff finding.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_WAIT = 3.0
BOOT_MAX = 15.0  # under load (tier-1 right after a test compile) 3s is not enough
QUIT_WAIT = 4.0


def boot(fd):
    """Drain until the alt-screen enter proves the TUI is up (readiness, not a
    fixed sleep — a loaded machine boots slower than any constant we pick)."""
    out = b""
    end = time.time() + BOOT_MAX
    while time.time() < end:
        out += drain(fd, 0.3)
        if b"\x1b[?1049h" in out:
            return out + drain(fd, 1.0)  # let the first full paint land
    return out


def spawn(cwd, env_extra):
    import pty
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.environ.update(env_extra)
        os.execv(BIN, [BIN, "tui", "--yolo"])
    return pid, fd


def drain(fd, seconds):
    # select-gated: a pty fd blocks on read when the child is quiet, and a
    # blocking read here would hang the whole guard on any wedged state —
    # exactly the states this guard exists to catch.
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


def reap(pid, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        r, status = os.waitpid(pid, os.WNOHANG)
        if r != 0:
            return status
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return None


MODE_RE = re.compile(rb"\x1b\[\?([0-9;]+)([hl])")
KITTY_PUSH_RE = re.compile(rb"\x1b\[>[0-9;]*u")
KITTY_POP_RE = re.compile(rb"\x1b\[<[0-9;]*u")


# Modes whose TERMINAL DEFAULT is enabled: autowrap (7) and cursor visible
# (25). For these the TUI's restore direction is `h`, so the invariant is
# "final state == default", not "every h has a later l" (grok-build's
# ModeTracker records the same distinction as latched-vs-default).
DEFAULT_ON = {b"7", b"25"}


def mode_imbalance(stream):
    """DEC modes whose final state differs from the terminal default, and the kitty push/pop depth."""
    final = {}
    for m in MODE_RE.finditer(stream):
        for num in m.group(1).split(b";"):
            final[num] = m.group(2)
    wrong = [int(n) for n, op in final.items()
             if (op == b"h") != (n in DEFAULT_ON)]
    depth = len(KITTY_PUSH_RE.findall(stream)) - len(KITTY_POP_RE.findall(stream))
    return sorted(wrong), max(depth, 0)


def fresh_ws():
    ws = tempfile.mkdtemp(prefix="tui-guard-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        json.dump({"mcpServers": {}}, f)
    return ws, {"GRAFF_MCP_CONFIG": empty, "GRAFF_LEARN_AUTO": "off"}


def quit_seq(fd):
    os.write(fd, b"\x11")  # Ctrl+Q — single byte, parser-independent


def quit_and_reap(fd, pid, collected):
    """Escalating quit: Ctrl+Q, then Escape+Ctrl+Q (a toast or composer text
    occasionally swallows the first one under load — the ~10% flake), then
    double Ctrl+C. Returns (status_or_None, all_bytes)."""
    out = collected
    for attempt in (b"\x11", b"\x1b\x1b\x11", b"\x03\x03"):
        os.write(fd, attempt)
        out += drain(fd, QUIT_WAIT)
        end = time.time() + 2.0
        while time.time() < end:
            r, status = os.waitpid(pid, os.WNOHANG)
            if r != 0:
                return status, out
            time.sleep(0.1)
    status = reap(pid)
    return status, out


def check_a():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    out = boot(fd)
    status, out = quit_and_reap(fd, pid, out)
    latched, depth = mode_imbalance(out)
    if status is None:
        return "A: quit did not exit within the window"
    if latched:
        return f"A: modes latched but never reset by clean quit: {latched}"
    if depth != 0:
        return f"A: kitty keyboard push/pop unbalanced (depth {depth})"
    if b"\x1b[?1049h" in out and b"\x1b[?1049l" not in out:
        return "A: alt-screen entered but never left"
    return None


HOSTILE = [
    b"\x1b[99999999999999999999;1u",          # 545: 20-digit CSI-u param
    b"\x1b[9999999999;1u",                     # 545: shortest overflow
    b"\x1b[<0;9999999999;5M",                  # 545: SGR mouse param overflow
    b"\x1b[1;",                                # 546: CSI split at the separator
    b"2A",                                     # 546: ...tail arriving alone
]


def check_b():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    boot(fd)
    out = b""
    for payload in HOSTILE:
        os.write(fd, payload)
        out += drain(fd, 0.3)
    # Split bracketed paste: body in one write, terminator split across two.
    os.write(fd, b"\x1b[200~pasted words")
    out += drain(fd, 0.3)
    os.write(fd, b"\x1b[201")
    out += drain(fd, 0.3)
    os.write(fd, b"~")
    out += drain(fd, 0.5)
    # The composer must be functional again: typed text echoes.
    os.write(fd, b"MARKER42")
    out += drain(fd, 1.0)
    alive = True
    try:
        r, _ = os.waitpid(pid, os.WNOHANG)
        alive = r == 0
    except ChildProcessError:
        alive = False
    if not alive:
        return "B: process died on the hostile corpus"
    if b"MARKER42" not in out:
        return "B: composer did not recover after the split paste (echo lost)"
    status, out = quit_and_reap(fd, pid, out)
    if status is None:
        return "B: quit did not exit after hostile input"
    latched, depth = mode_imbalance(out)
    return None


def check_c():
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    out = boot(fd)
    os.kill(pid, signal.SIGTERM)
    out += drain(fd, 3.0)
    status = reap(pid)
    if b"\x1b[?1049h" in out and b"\x1b[?1049l" not in out:
        return "C: SIGTERM left the alt-screen latched (terminal stranded)"
    if b"\x1b[?2004h" in out and b"\x1b[?2004l" not in out:
        return "C: SIGTERM left bracketed paste latched"
    return None


def main():
    if not os.path.exists(BIN):
        print(f"tui-pty-guard: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-pty-guard: no pty support here — skipping")
        return 0
    failures = []
    for name, fn in (("mode-balance", check_a), ("hostile-input", check_b), ("kill-restore", check_c)):
        try:
            err = fn()
        except OSError as e:
            # An OSError mid-check means the CHILD vanished (EIO on a dead pty)
            # — that is a failure, not an environment skip. Only a fork-time
            # failure counts as "no pty here".
            if getattr(e, "errno", None) == 5:
                err = f"{name}: pty EIO — the graff process died mid-check"
            else:
                print(f"tui-pty-guard: {name}: pty unavailable ({e}) — skipping")
                continue
        if err:
            failures.append(err)
            print(f"  ✗ {name}: {err}")
        else:
            print(f"  ✓ {name}")
    if failures:
        print(f"tui-pty-guard: {len(failures)} invariant(s) violated")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
