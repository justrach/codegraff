#!/usr/bin/env python3
"""Run the 18 tuiguard PTY probes as a process pool (#641).

Each probe owns its own pty/tmp/mock and is independent of the others. The
serial loop in eval-tier1.sh was the dominant post-src wall (2–4 min). A 4–8
worker pool brings that to roughly one long probe (fold-headers / hover).

Usage: python3 scripts/eval/tier1_tuiguard.py [path/to/graff]
Exit 0 when every probe passes (or skips itself); 1 if any fails.
GRAFF_TUIGUARD_JOBS overrides the pool size (default: min(8, cpu_count)).
"""

from __future__ import annotations

import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

PROBES = (
    "tui-pty-guard.py",
    "test-tui-escape-split.py",
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


def _jobs() -> int:
    raw = os.environ.get("GRAFF_TUIGUARD_JOBS", "").strip()
    if raw.isdigit() and int(raw) > 0:
        return int(raw)
    cpus = os.cpu_count() or 4
    return max(1, min(8, cpus, len(PROBES)))


def run_probe(script: str, binary: str) -> tuple[str, int, str]:
    path = SCRIPTS / script
    proc = subprocess.run(
        [sys.executable, str(path), binary],
        cwd=ROOT,
        capture_output=True,
        text=True,
        errors="replace",
    )
    blob = (proc.stdout + proc.stderr).rstrip()
    return script, proc.returncode, blob


def main() -> int:
    binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/graff")
    if not os.path.isfile(binary):
        print(f"  tuiguard: no binary at {binary}", file=sys.stderr)
        return 1
    jobs = _jobs()
    print(f"  {len(PROBES)} probes, {jobs} workers")
    failed: list[str] = []
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run_probe, name, binary): name for name in PROBES}
        for fut in as_completed(futs):
            script, status, blob = fut.result()
            if blob:
                for line in blob.splitlines():
                    print(f"  [{script}] {line}")
            if status != 0:
                failed.append(script)
                print(f"  FAIL {script} (exit {status})")
            else:
                print(f"  ok   {script}")
    if failed:
        print(f"  {len(failed)}/{len(PROBES)} probes failed: {', '.join(failed)}")
        return 1
    print(f"  all {len(PROBES)} probes passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
