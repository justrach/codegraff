#!/usr/bin/env python3
"""Time codedb one-shots vs hop chains, then run the matching tier-2 harness cases.

Engine numbers use the codedb CLI on this repo. Harness numbers are graff
--json + the scripted model: tool_call count and tool_call_finished.ms.
"""

from __future__ import annotations

import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
import importlib.util

_spec = importlib.util.spec_from_file_location("eval_tier2", REPO / "scripts" / "eval-tier2.py")
_tier2 = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_tier2)
execute = _tier2.execute
evaluate = _tier2.evaluate
load_cases = _tier2.load_cases


def timed_cli(codedb: str, root: str, args: list[str], rounds: int = 5) -> dict:
    times = []
    out = b""
    rc = 0
    for i in range(1 + rounds):
        t0 = time.perf_counter()
        p = subprocess.run([codedb, root, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        dt = (time.perf_counter() - t0) * 1000
        if i:
            times.append(dt)
            out, rc = p.stdout, p.returncode
    return {
        "cmd": " ".join(args),
        "ms": statistics.median(times),
        "bytes": len(out),
        "rc": rc,
    }


def engine_table(codedb: str, root: str) -> None:
    jobs = [
        ("explain hops", [["symbol", "companionRoute", "--body"], ["callers", "companionRoute"]]),
        ("explain one-shot", [["explain", "companionRoute"]]),
        ("context hops", [["search", "codedb pro lookup"], ["word", "lookup"], ["symbol", "lookup"]]),
        ("context one-shot", [["context", "how does codedb-pro lookup cache composed answers"]]),
        ("callpath hops", [["symbol", "companionRoute"], ["symbol", "companionNativeFallback"], ["callers", "companionNativeFallback"]]),
        ("callpath one-shot", [["callpath", "companionRoute", "companionNativeFallback"]]),
        ("list_dir", [["list_dir", "src"]]),
        ("status", [["status"]]),
    ]
    print("engine (codedb CLI, this repo)")
    print(f"{'surface':<22} {'rpcs':>4} {'med ms':>8}")
    for name, cmds in jobs:
        parts = [timed_cli(codedb, root, c) for c in cmds]
        total = sum(p["ms"] for p in parts)
        print(f"{name:<22} {len(cmds):4d} {total:8.1f}")


def harness_table(graff: str) -> None:
    ids = [
        "codedb-oneshot-around-is-one-rpc",
        "codedb-hop-explain-is-two-rpcs",
        "codedbpro-lookup-is-one-rpc",
        "codedbpro-hop-explain-is-three-rpcs",
    ]
    cases = {c["id"]: c for c in load_cases() if c["id"] in ids}
    print()
    print("harness (graff --json, scripted model)")
    print(f"{'case':<38} {'tools':>5} {'tool ms':>8} {'wall s':>7} result")
    port = 1234
    for cid in ids:
        case = cases[cid]
        t0 = time.perf_counter()
        run = execute(case, graff, port, None, None)
        wall = time.perf_counter() - t0
        problems = evaluate(case, run, live=False)
        if run.exit_code != case.get("expected_exit", 0):
            problems.append(f"exit {run.exit_code}")
        calls = [e for e in run.events if e.get("type") == "tool_call"]
        finished = [e for e in run.events if e.get("type") == "tool_call_finished"]
        tool_ms = sum(int(e.get("ms") or 0) for e in finished)
        status = "pass" if not problems else "FAIL " + "; ".join(problems)[:60]
        print(f"{cid:<38} {len(calls):5d} {tool_ms:8d} {wall:7.1f} {status}")


def main() -> None:
    codedb = os.environ.get("CODEDB", "/tmp/codedb-bin/codedb")
    graff = os.environ.get("GRAFF", str(REPO / "zig-out" / "bin" / "graff"))
    if not Path(codedb).exists():
        sys.exit(f"no codedb at {codedb}")
    if not Path(graff).exists():
        sys.exit(f"no graff at {graff} — zig build first")
    codedb_dir = str(Path(codedb).resolve().parent)
    os.environ["PATH"] = codedb_dir + os.pathsep + os.environ.get("PATH", "")
    engine_table(codedb, str(REPO))
    if "--engine-only" not in sys.argv:
        harness_table(graff)


if __name__ == "__main__":
    main()
