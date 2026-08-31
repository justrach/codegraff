#!/usr/bin/env python3
"""Run the 17 tuiguard PTY probes as a process pool (#641 / #704).

Each probe owns its own pty/tmp/mock and is independent of the others. The
serial loop in eval-tier1.sh was the dominant post-src wall (2–4 min). A 4–8
worker pool brings that to roughly one long probe (fold-headers / hover).

A wedged child used to keep the pool (and therefore pre-push) alive for
hours: `subprocess.run` and `as_completed` had no deadline (#704). Each
probe now has an explicit timeout that kills its process group, the parent
has a wave-budget deadline, and a timeout names the still-running scripts.

Usage: python3 scripts/eval/tier1_tuiguard.py [path/to/graff]
Exit 0 when every probe passes (or skips itself); 1 if any fails.
GRAFF_TUIGUARD_JOBS overrides the pool size (default: min(8, cpu_count)).
GRAFF_TUIGUARD_PROBE_TIMEOUT overrides every per-probe deadline (seconds).
"""

from __future__ import annotations

import math
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

PROBES = (
    "tui-pty-guard.py",
    "test-tui-selection.py",
    "test-tui-typed-events.py",
    "test-tui-painter.py",
    "test-tui-layout-cache.py",
    "test-tui-resize-anchor.py",
    "test-tui-chrome-width.py",
    "test-tui-scroll-paint.py",
    "test-tui-event-pacing.py",
    "test-tui-screenstate.py",
    "test-tui-fold-headers.py",
    "test-tui-stream-markdown.py",
    "test-tui-hover.py",
    "test-tui-click.py",
    "test-tui-scrollbar-osc52.py",
    "test-tui-overlay-panels.py",
    "test-tui-model-picker.py",
)

# Warm-run walls from a green 4-worker pool: click ~35s, hover ~20s,
# model-picker ~19s. 90s is ~2.5× the longest; the rest stay at 60s.
DEFAULT_TIMEOUT = 60.0
LONG_TIMEOUT = 90.0
PARENT_SLACK = 60.0
PROBE_TIMEOUTS = {
    "test-tui-click.py": LONG_TIMEOUT,
    "test-tui-hover.py": LONG_TIMEOUT,
    "test-tui-fold-headers.py": LONG_TIMEOUT,
    "test-tui-model-picker.py": LONG_TIMEOUT,
    "test-tui-layout-cache.py": LONG_TIMEOUT,
}


def _jobs() -> int:
    raw = os.environ.get("GRAFF_TUIGUARD_JOBS", "").strip()
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    cpus = os.cpu_count() or 4
    return max(1, min(8, cpus, len(PROBES)))


def probe_timeout(script: str) -> float:
    raw = os.environ.get("GRAFF_TUIGUARD_PROBE_TIMEOUT", "").strip()
    if raw:
        return float(raw)
    return PROBE_TIMEOUTS.get(script, DEFAULT_TIMEOUT)


def parent_budget(jobs: int, names: tuple[str, ...] = PROBES) -> float:
    """Worst-case wall: ceil(n/jobs) waves of the longest probe, plus slack."""
    workers = max(1, jobs)
    waves = math.ceil(len(names) / workers)
    longest = max(probe_timeout(n) for n in names) if names else DEFAULT_TIMEOUT
    return waves * longest + PARENT_SLACK


def terminate_group(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    if os.name == "posix":
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            return
        except OSError:
            pass
    proc.kill()


def run_command(argv: list[str], timeout: float, cwd: Path | None = None) -> tuple[int, str, float, bool]:
    """Run argv in its own session. On timeout, kill the whole group."""
    t0 = time.monotonic()
    proc = subprocess.Popen(
        argv,
        cwd=str(cwd or ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
        elapsed = time.monotonic() - t0
        return proc.returncode or 0, (out or "").rstrip(), elapsed, False
    except subprocess.TimeoutExpired:
        terminate_group(proc)
        leftover, _ = proc.communicate()
        elapsed = time.monotonic() - t0
        blob = (leftover or "").rstrip()
        return 124, blob, elapsed, True


def run_probe(script: str, binary: str, timeout: float) -> tuple[str, int, str, float, bool]:
    status, blob, elapsed, timed_out = run_command(
        [sys.executable, str(SCRIPTS / script), binary],
        timeout,
    )
    return script, status, blob, elapsed, timed_out


def run_pool(
    binary: str,
    probes: tuple[str, ...] = PROBES,
    jobs: int | None = None,
    parent_seconds: float | None = None,
) -> int:
    workers = jobs if jobs is not None else _jobs()
    print(f"  {len(probes)} probes, {workers} workers")
    failed: list[str] = []
    raw_parent = os.environ.get("GRAFF_TUIGUARD_PARENT_TIMEOUT", "").strip()
    if parent_seconds is not None:
        budget = parent_seconds
    elif raw_parent:
        budget = float(raw_parent)
    else:
        budget = parent_budget(workers, probes)
    deadline = time.monotonic() + budget
    # Threads wait on per-probe Popen; the probe is already a process group.
    # A process pool hid child output until join and could not abandon a
    # wedged worker without waiting on the context manager (#704).
    pool = ThreadPoolExecutor(max_workers=max(1, workers))
    try:
        futs = {
            pool.submit(run_probe, name, binary, probe_timeout(name)): name
            for name in probes
        }
        pending = set(futs)
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                stuck = ", ".join(sorted(futs[f] for f in pending))
                print(f"  tuiguard: parent deadline; still running: {stuck}")
                return 1
            done, pending = wait(
                pending, timeout=min(remaining, 0.25), return_when=FIRST_COMPLETED
            )
            for fut in done:
                script, status, blob, elapsed, timed_out = fut.result()
                if blob:
                    for line in blob.splitlines():
                        print(f"  [{script}] {line}")
                print(f"  [{script}] {elapsed:.1f}s")
                if timed_out:
                    failed.append(script)
                    print(f"  FAIL {script} (timeout after {elapsed:.1f}s)")
                elif status != 0:
                    failed.append(script)
                    print(f"  FAIL {script} (exit {status})")
                else:
                    print(f"  ok   {script}")
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    if failed:
        print(f"  {len(failed)}/{len(probes)} probes failed: {', '.join(failed)}")
        return 1
    print(f"  all {len(probes)} probes passed")
    return 0


def main() -> int:
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
    if not os.path.isfile(binary):
        print(f"  tuiguard: no binary at {binary}", file=sys.stderr)
        return 1
    return run_pool(binary)


if __name__ == "__main__":
    raise SystemExit(main())
