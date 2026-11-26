#!/usr/bin/env python3
"""30-shell-call loop against bench/shell/fake_model.go.

Measures wall time from the first tool_call JSON event to the last tool_result.
Default: 3 warm-ups, then 20 timed runs; prints median and p90.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * p
    lo = int(rank)
    hi = min(lo + 1, len(ordered) - 1)
    frac = rank - lo
    return ordered[lo] * (1 - frac) + ordered[hi] * frac


def start_model() -> tuple[subprocess.Popen, int]:
    proc = subprocess.Popen(
        ["go", "run", "."],
        cwd=HERE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdout is not None
    line = proc.stdout.readline().strip()
    if not line.startswith("PORT="):
        err = proc.stderr.read() if proc.stderr else ""
        proc.kill()
        raise RuntimeError(f"fake model did not print PORT= ({line!r}): {err}")
    return proc, int(line.split("=", 1)[1])


def prepare_workspace(root: Path, port: int, mcp: Path) -> None:
    graff = root / ".graff"
    graff.mkdir(parents=True, exist_ok=True)
    (graff / ".config.router").write_text(json.dumps({
        "id": "tier2",
        "base_url": f"http://127.0.0.1:{port}/v1",
        "env_key": "TIER2_API_KEY",
        "default_model": "mock",
    }), encoding="utf-8")
    (root / ".mcp.json").write_text(json.dumps({
        "mcpServers": {
            "noop": {"command": sys.executable, "args": [str(mcp)]},
        }
    }), encoding="utf-8")


def reset_model(port: int) -> None:
    import urllib.request
    req = urllib.request.Request(f"http://127.0.0.1:{port}/reset", method="POST")
    with urllib.request.urlopen(req, timeout=5) as resp:
        resp.read()


def one_run(graff: str, workspace: Path) -> tuple[float, int, int, str]:
    env = {
        key: value for key, value in os.environ.items()
        if not key.endswith("_API_KEY")
    }
    env.update({
        "HOME": str(workspace),
        "TIER2_API_KEY": "local",
        "GRAFF_NO_TELEMETRY": "1",
        "GRAFF_FLEET": "off",
        "GRAFF_NO_SMOLIFY": "1",
        "NO_COLOR": "1",
    })
    prompt = json.dumps({"type": "user", "text": "run the shell loop"}) + "\n"
    proc = subprocess.Popen(
        [graff, "--json", "--yolo", "--model", "tier2/mock"],
        cwd=workspace,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(prompt)
    proc.stdin.close()
    first = None
    last = None
    calls = 0
    results = 0
    for raw in proc.stdout:
        now = time.perf_counter()
        line = raw.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "tool_call":
            calls += 1
            if first is None:
                first = now
        elif kind == "tool_result":
            results += 1
            last = now
    stderr = proc.stderr.read() if proc.stderr else ""
    code = proc.wait(timeout=120)
    if code != 0:
        raise RuntimeError(f"graff exited {code}: {stderr[-2000:]}")
    if first is None or last is None:
        raise RuntimeError(f"missing tool events (calls={calls} results={results}): {stderr[-2000:]}")
    return (last - first) * 1000.0, calls, results, stderr


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", default=str(REPO / "zig-out" / "bin" / "graff"))
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--runs", type=int, default=20)
    args = parser.parse_args()
    graff = str(Path(args.graff).resolve())
    if not Path(graff).is_file():
        print(f"missing graff binary: {graff}", file=sys.stderr)
        return 2

    model, port = start_model()
    try:
        times: list[float] = []
        with tempfile.TemporaryDirectory(prefix="graff-shell-bench-") as tmp:
            root = Path(tmp)
            prepare_workspace(root, port, HERE / "mcp_noop.py")
            for i in range(args.warmups + args.runs):
                reset_model(port)
                workspace = root / f"run-{i}"
                shutil.copytree(root / ".graff", workspace / ".graff", dirs_exist_ok=True)
                (workspace / ".mcp.json").write_text((root / ".mcp.json").read_text(encoding="utf-8"), encoding="utf-8")
                ms, calls, results, _ = one_run(graff, workspace)
                label = "warmup" if i < args.warmups else f"run {i - args.warmups + 1:02d}"
                print(f"{label}: {ms:.1f} ms  tool_call={calls} tool_result={results}", flush=True)
                if i >= args.warmups:
                    times.append(ms)
        if not times:
            print("no timed runs", file=sys.stderr)
            return 1
        med = statistics.median(times)
        p90 = percentile(times, 0.90)
        print(f"n={len(times)} median={med:.1f} ms p90={p90:.1f} ms min={min(times):.1f} ms max={max(times):.1f} ms")
        return 0
    finally:
        model.terminate()
        try:
            model.wait(timeout=5)
        except subprocess.TimeoutExpired:
            model.kill()
            model.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
