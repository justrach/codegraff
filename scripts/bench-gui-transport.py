#!/usr/bin/env python3
"""Measure the GUI backend's subprocess-per-turn transport overhead.

This benchmark intentionally avoids model/provider network work. It exercises the
same `graff --json` stdio protocol that the Zig GUI backend uses, but sends cheap
control requests (`set_fast`) instead of a user turn. That isolates process
startup + JSONL protocol overhead so we have a number before considering a
persistent-child or `graff serve` architecture.

Examples:
  scripts/bench-gui-transport.py --binary zig-out/bin/graff --iterations 25
  scripts/bench-gui-transport.py --binary graff --cwd /tmp --iterations 50 --json
"""
from __future__ import annotations

import argparse
import json
import os
import selectors
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Measurement:
    name: str
    samples_ms: list[float]

    def summary(self) -> dict[str, float | int | str]:
        samples = sorted(self.samples_ms)
        if not samples:
            return {"name": self.name, "n": 0}
        p95_idx = min(len(samples) - 1, int(round((len(samples) - 1) * 0.95)))
        return {
            "name": self.name,
            "n": len(samples),
            "min_ms": samples[0],
            "median_ms": statistics.median(samples),
            "mean_ms": statistics.fmean(samples),
            "p95_ms": samples[p95_idx],
            "max_ms": samples[-1],
        }


def percentile(samples: list[float], q: float) -> float:
    values = sorted(samples)
    if not values:
        return 0.0
    return values[min(len(values) - 1, int(round((len(values) - 1) * q)))]


def wait_for_ack(proc: subprocess.Popen[str], expected: str, timeout_s: float = 10.0) -> None:
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout_s
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for {expected!r} ack")
            events = selector.select(remaining)
            if not events:
                continue
            raw = proc.stdout.readline()
            if raw == "":
                raise RuntimeError(f"graff closed stdout before {expected!r} ack")
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ty = event.get("type")
            if ty == "error":
                raise RuntimeError(f"graff error event: {event.get('message', raw)}")
            if ty == expected:
                return
    finally:
        selector.close()


def subprocess_once(binary: str, cwd: str, request: str) -> float:
    start = time.perf_counter()
    proc = subprocess.Popen(
        [binary, "--json"],
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        assert proc.stdin is not None
        proc.stdin.write(request + "\n")
        proc.stdin.close()
        wait_for_ack(proc, "fast")
        rc = proc.wait(timeout=10)
        if rc != 0:
            raise RuntimeError(f"graff exited with {rc}")
        return (time.perf_counter() - start) * 1000.0
    except Exception:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        raise


def persistent_session(binary: str, cwd: str, requests: Iterable[str]) -> list[float]:
    proc = subprocess.Popen(
        [binary, "--json"],
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    assert proc.stdin is not None
    samples: list[float] = []
    try:
        for request in requests:
            start = time.perf_counter()
            proc.stdin.write(request + "\n")
            proc.stdin.flush()
            wait_for_ack(proc, "fast")
            samples.append((time.perf_counter() - start) * 1000.0)
    finally:
        try:
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    return samples


def print_table(measurements: list[Measurement]) -> None:
    print("transport benchmark (cheap JSON control request; no model call)")
    print("name                         n    median     mean      p95      min      max")
    for m in measurements:
        s = m.summary()
        print(
            f"{s['name']:<28} {s['n']:>3} "
            f"{s['median_ms']:>8.1f} {s['mean_ms']:>8.1f} {s['p95_ms']:>8.1f} "
            f"{s['min_ms']:>8.1f} {s['max_ms']:>8.1f}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=os.environ.get("CODEGRAFF_GUI_BINARY", "graff"))
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--json", action="store_true", dest="json_output")
    args = parser.parse_args()

    request = json.dumps({"type": "set_fast", "on": False})
    if args.iterations < 1:
        parser.error("--iterations must be >= 1")

    # One warmup lets dynamic linker/filesystem cache noise settle without
    # hiding the subprocess-per-turn cost in the reported samples.
    subprocess_once(args.binary, args.cwd, request)

    per_turn = [subprocess_once(args.binary, args.cwd, request) for _ in range(args.iterations)]
    persistent = persistent_session(args.binary, args.cwd, [request] * args.iterations)
    measurements = [
        Measurement("spawn-per-request", per_turn),
        Measurement("persistent-child", persistent),
    ]

    payload = {
        "binary": args.binary,
        "cwd": args.cwd,
        "iterations": args.iterations,
        "measurements": [m.summary() for m in measurements],
        "spawn_penalty_median_ms": statistics.median(per_turn) - statistics.median(persistent),
        "spawn_penalty_p95_ms": percentile(per_turn, 0.95) - percentile(persistent, 0.95),
    }
    if args.json_output:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print_table(measurements)
        print(
            f"\nmedian subprocess penalty: {payload['spawn_penalty_median_ms']:.1f} ms "
            f"(p95 delta {payload['spawn_penalty_p95_ms']:.1f} ms)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
