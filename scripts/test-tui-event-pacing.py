#!/usr/bin/env python3
"""Live proof that a trackpad wheel storm is COALESCED and BUDGETED, not queued.

Trackpad momentum fires wheel reports far faster than a frame can be composed
and painted. Serviced one report per frame the loop queues work it can never
catch up on: the scroll trails the fingers and then jumps. The fix is in
run.zig's tick (drain everything, fold consecutive wheel reports into one
delta, one frame per tick, at most one per ~8ms while input keeps arriving).

Everything else about that lives in unit tests over pure functions. This probe
puts a real `graff tui` under a pty and measures the loop from OUTSIDE, using
the local-only counters GRAFF_TUI_PAINT_STATS=1 prints on exit:

  A. control      A session that is never scrolled at all. Its paint count is
                  the floor everything else is measured against, so booting,
                  the transcript fill and the idle self-heal cannot be
                  mistaken for storm work.
  B. storm        500 SGR wheel reports pushed in under a second. The paint
                  count above the control floor must be BUDGETED (~one per
                  8ms of storm), not one per report, and the 500 reports must
                  collapse into a handful of applied scroll deltas.
  C. responsive   A marker typed straight after the storm must echo within
                  50ms — keys are never starved behind the flood.
  D. no lag tax   A SINGLE wheel report on an idle session must paint at once.
                  The budget exists for storms; it may not tax one flick.

Usage: python3 scripts/test-tui-event-pacing.py [path/to/graff]
Exit 0 = pass (or a skip when no pty is available).
"""
import os
import re
import select
import sys
import tempfile
import time

# Absolutized BEFORE the fork: the child chdirs into its scratch workspace.
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
BOOT_MAX = 15.0
ROWS, COLS = 30, 100

UP = b"\x1b[<64;20;10M"
DOWN = b"\x1b[<65;20;10M"
FLINGS, PER_FLING = 10, 50
STORM_N = FLINGS * PER_FLING
# How long the PACED storm is spread over — 500 reports in under a second, the
# rate a trackpad fling really sustains.
PACED_S = 0.9

MARK = b"PACEMARK"
ECHO_BUDGET_MS = 50.0
# One report on an idle loop must paint immediately; this is a generous ceiling
# on "immediately" for a loaded CI box, and still an order below a queued loop.
SINGLE_BUDGET_MS = 50.0
# run.zig's pacing.frame_budget_ms. A storm that takes `t` ms may paint about
# t/8 times; the slack absorbs the idle self-heal and a loaded machine.
FRAME_BUDGET_MS = 8.0

STATS = re.compile(rb"tui-paint-stats:((?: \w+=\d+)+)")


def drain(fd, seconds):
    # select-gated: a quiet pty blocks on read, and a blocking read would hang
    # the probe on exactly the wedged states it exists to catch.
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
    ws = tempfile.mkdtemp(prefix="tui-pacing-")
    empty = os.path.join(ws, "empty-mcp.json")
    with open(empty, "w") as f:
        f.write('{"mcpServers": {}}')
    return ws, {
        "GRAFF_MCP_CONFIG": empty,
        "GRAFF_LEARN_AUTO": "off",
        "GRAFF_TUI_PAINT_STATS": "1",
    }


def quit_and_stats(pid, fd):
    """Escalating quit, then the counters the loop prints after the restore."""
    import signal
    tail = b""
    try:
        os.write(fd, b"\x11")  # Ctrl+Q
        end = time.time() + 4.0
        while time.time() < end:
            tail += drain(fd, 0.3)
            if STATS.search(tail):
                break
    except OSError:
        pass
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except OSError:
            break
        time.sleep(0.05)
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    m = STATS.search(tail)
    if not m:
        return None
    out = {}
    for pair in m.group(1).split():
        k, v = pair.decode().split("=")
        out[k] = int(v)
    return out


def fill_transcript(fd):
    """A transcript tall enough that scrolling always changes the frame — a
    storm over an empty screen would compose the same bytes every time and
    prove nothing about paints."""
    for _ in range(5):
        os.write(fd, b"!seq 1 40\r")
        drain(fd, 1.6)
    return drain(fd, 0.5)


def push_paced(fd, data_units, total_s):
    """Deliver reports SPREAD OVER TIME, the way trackpad momentum really
    arrives. This is the case a backlog check cannot see: the loop reads each
    report the instant it lands, finds nothing queued behind it, and — without
    a rate-based budget — paints once per report. Returns (seconds, sent)."""
    gap = total_s / len(data_units)
    start = time.perf_counter()
    sent = 0
    os.set_blocking(fd, False)
    try:
        for i, unit in enumerate(data_units):
            target = start + i * gap
            while True:
                left = target - time.perf_counter()
                if left <= 0:
                    break
                # Drain output while waiting: the child's output queue is a few
                # KB and a child blocked writing is not a child under storm.
                r, _, _ = select.select([fd], [], [], min(left, 0.002))
                if r:
                    try:
                        os.read(fd, 65536)
                    except (BlockingIOError, OSError):
                        pass
            for _ in range(200):
                try:
                    os.write(fd, unit)
                    sent += 1
                    break
                except BlockingIOError:
                    select.select([], [fd], [], 0.002)
                except OSError:
                    return time.perf_counter() - start, sent
    finally:
        os.set_blocking(fd, True)
    return time.perf_counter() - start, sent


def push(fd, data, deadline=5.0):
    """Write while reading. The pty's input queue is ~1KB and the child's output
    queue is a few KB, so a write-only loop deadlocks against a child that is
    painting. The master goes NON-BLOCKING for the burst: select reports the fd
    writable when there is *any* room, and a blocking write of a full chunk then
    parks in the kernel until the whole chunk fits. Returns (seconds, output)."""
    out = b""
    i = 0
    start = time.time()
    os.set_blocking(fd, False)
    try:
        while i < len(data) and time.time() - start < deadline:
            r, wl, _ = select.select([fd], [fd], [], 0.1)
            if fd in r:
                try:
                    out += os.read(fd, 65536)
                except BlockingIOError:
                    pass
                except OSError:
                    break
            if fd in wl:
                try:
                    i += os.write(fd, data[i : i + 512])
                except BlockingIOError:
                    continue
                except OSError:
                    break
    finally:
        os.set_blocking(fd, True)
    return time.time() - start, out


def wait_for(fd, needle, budget_s):
    """Seconds until `needle` shows up in the pty output, or None."""
    out = b""
    start = time.time()
    while time.time() - start < budget_s:
        r, _, _ = select.select([fd], [], [], 0.005)
        if not r:
            continue
        try:
            out += os.read(fd, 65536)
        except OSError:
            break
        if needle in out:
            return time.time() - start
    return None


def session(mode):
    """One pty session: "control", "burst" or "paced". Returns (stats, err, extras)."""
    ws, env = fresh_ws()
    pid, fd = spawn(ws, env)
    extras = {}
    try:
        boot(fd)
        fill_transcript(fd)
        reports = []
        for f in range(FLINGS):
            reports += [UP if f % 2 == 0 else DOWN] * PER_FLING
        if mode == "burst":
            secs, _ = push(fd, b"".join(reports))
            extras["burst_s"] = secs
            if secs >= 1.0:
                return None, f"the {STORM_N}-report burst took {secs:.2f}s, not <1s", extras
        elif mode == "paced":
            secs, sent = push_paced(fd, reports, PACED_S)
            extras["paced_s"] = secs
            if sent < STORM_N:
                return None, f"only {sent}/{STORM_N} paced reports were written", extras
        if mode != "control":
            # C: typing straight after the storm, while the loop is still
            # settling. A key must never sit behind the flood.
            os.write(fd, MARK)
            echo = wait_for(fd, MARK, ECHO_BUDGET_MS / 1000.0 * 4)
            extras["echo_ms"] = None if echo is None else echo * 1000.0
            os.write(fd, b"\x15")  # Ctrl+U: leave the composer empty again
            drain(fd, 0.4)
            # D: one lone report on a quiet loop must paint on the spot — the
            # budget exists for storms and may not tax a single flick.
            t0 = time.time()
            os.write(fd, UP)
            r, _, _ = select.select([fd], [], [], SINGLE_BUDGET_MS / 1000.0 * 4)
            extras["single_ms"] = (time.time() - t0) * 1000.0 if r else None
            if r:
                os.read(fd, 65536)
        drain(fd, 0.4)
        return quit_and_stats(pid, fd), None, extras
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def check_storm(name, control, stats, extras, elapsed_s, min_batches, max_batches):
    seen = stats["wheel_events"]
    batches = stats["wheel_batches"]
    extra_paints = stats["paints"] - control["paints"]
    extras[f"{name}_events"] = seen
    extras[f"{name}_deltas"] = batches
    extras[f"{name}_paints"] = extra_paints
    if seen < STORM_N * 0.95:
        return f"{name}: only {seen}/{STORM_N} wheel reports reached the loop — lost, not paced"
    # A storm that moved nothing would make "few paints" the trivial answer.
    if extra_paints < 2:
        return f"{name}: the storm changed the frame {extra_paints} times — it never scrolled anything"
    # THE claim: paints are budgeted by the clock, not by the report count.
    ceiling = max(20, int(elapsed_s * 1000.0 / FRAME_BUDGET_MS) + 25)
    if extra_paints > ceiling:
        return f"{name}: {seen} reports cost {extra_paints} paints over {elapsed_s * 1000:.0f}ms (the ~8ms budget allows ~{ceiling})"
    if not (min_batches <= batches <= max_batches):
        return f"{name}: {seen} reports applied as {batches} scroll deltas (expected {min_batches}..{max_batches})"
    if extras.get("echo_ms") is None:
        return f"{name}: a marker typed after the storm never echoed — typing was starved"
    if extras["echo_ms"] > ECHO_BUDGET_MS:
        return f"{name}: the marker took {extras['echo_ms']:.1f}ms to echo (budget {ECHO_BUDGET_MS:.0f}ms)"
    if extras.get("single_ms") is None:
        return f"{name}: a single wheel report on an idle loop never painted"
    if extras["single_ms"] > SINGLE_BUDGET_MS:
        return f"{name}: one report on an idle loop took {extras['single_ms']:.1f}ms — the budget is taxing single ticks"
    return None


def run():
    extras = {}
    control, err, _ = session("control")
    if err:
        return err, extras
    if control is None:
        return "the control session printed no tui-paint-stats line", extras
    if control["wheel_events"] != 0:
        return f"the control session saw {control['wheel_events']} wheel events; it must see none", extras
    extras["control_paints"] = control["paints"]

    # A: all at once. The tty hands the loop a backlog, so the reports fold
    # into a handful of deltas and cost a handful of paints.
    stats, err, ex = session("burst")
    extras.update(ex)
    if err:
        return err, extras
    if stats is None:
        return "the burst session printed no tui-paint-stats line", extras
    # +1 delta for the single-flick probe at the end of the session.
    err = check_storm("burst", control, stats, extras, extras["burst_s"], 2, 40)
    if err:
        return err, extras

    # B: spread over ~1s, the way momentum actually arrives. Nothing is ever
    # queued behind a report here, so ONLY the rate-based budget bounds the
    # paints — this is the case that fails if the budget looks at the backlog.
    stats, err, ex = session("paced")
    extras.update(ex)
    if err:
        return err, extras
    if stats is None:
        return "the paced session printed no tui-paint-stats line", extras
    # Nothing to fold when the reports arrive further apart than the loop takes
    # to service one, so the delta count is not the claim here — the paint count
    # is. The window only rules out an implementation that dropped reports.
    return check_storm("paced", control, stats, extras, extras["paced_s"], 2, STORM_N + 5), extras


def main():
    if not os.path.exists(BIN):
        print(f"tui-pacing: {BIN} not built — skipping")
        return 0
    try:
        import pty  # noqa: F401
    except ImportError:
        print("tui-pacing: no pty support here — skipping")
        return 0
    extras = None
    try:
        err, extras = run()
    except OSError as e:
        if getattr(e, "errno", None) == 5:
            err = "pty EIO — the graff process died mid-check"
        else:
            print(f"tui-pacing: pty unavailable ({e}) — skipping")
            return 0
    if extras:
        print(
            "    "
            + " ".join(
                f"{k}={v:.1f}" if isinstance(v, float) else f"{k}={v}"
                for k, v in extras.items()
                if v is not None
            )
        )
    if err:
        print(f"  ✗ pacing: {err}")
        return 1
    print(
        f"  ✓ pacing: {extras['burst_events']} reports at once → "
        f"{extras['burst_deltas']} deltas / {extras['burst_paints']} paints; "
        f"{extras['paced_events']} over {extras['paced_s'] * 1000:.0f}ms → "
        f"{extras['paced_paints']} paints (~{FRAME_BUDGET_MS:.0f}ms budget, not one per report); "
        f"typing echoed in {extras['echo_ms']:.1f}ms, one flick painted in {extras['single_ms']:.1f}ms"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
