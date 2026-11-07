#!/usr/bin/env python3
"""Compare plain Zig and declared-task caching without publishing a release."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_build", ROOT / "scripts/build-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def timed(metrics, name, operation):
    start = time.perf_counter()
    result = operation()
    metrics[name] = round(time.perf_counter() - start, 6)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=release.TARGETS)
    parser.add_argument("--mode", required=True, choices=("plain", "nano"))
    parser.add_argument("--phase", required=True, choices=("cold", "warm"))
    parser.add_argument("--portable-host", action="store_true")
    args = parser.parse_args()
    start = time.perf_counter()
    metrics = {"target": args.target, "mode": args.mode, "phase": args.phase,
               "host_identity": "platform" if args.portable_host else "native"}
    zig = Path(shutil.which("zig")).resolve()
    cache = ROOT / ".nanocompile-cache"
    env = release.environment(cache)

    def run(command):
        subprocess.run(command, cwd=ROOT, env=env, check=True)

    # Readiness validation is included, even when it avoids the native runner.
    metrics["dependencies_reused"] = timed(metrics, "fetch_seconds",
        lambda: release.fetch_dependencies(zig, env))
    contract, output = timed(metrics, "contract_seconds", lambda: release.contract(
        args.target, "0.302.43", zig, portable_host=args.portable_host))
    state_path = ROOT / ".benchmark-state" / (args.mode + "-" + args.target + ".json")
    expected = None
    if args.phase == "warm":
        expected = json.loads(state_path.read_text())["sha256"]
    if output.exists():
        raise RuntimeError("Benchmark requires an absent output before each invocation")
    command = contract["tasks"][0]["command"]
    events = cache / "events"
    offset = events.stat().st_size if events.exists() else 0
    if args.mode == "nano":
        spec_path = ROOT / ".zig-cache" / ("benchmark-" + args.target + ".json")
        spec_path.parent.mkdir(parents=True, exist_ok=True)
        spec_path.write_text(json.dumps(contract, sort_keys=True) + "\n")
        command = [os.environ["NANOCOMPILE_EXE"], "task", str(spec_path)]
    timed(metrics, "task_seconds", lambda: run(command))
    if args.mode == "nano":
        with events.open("rb") as source:
            source.seek(offset)
            hit = b"task_hit\n" in source.read()
        metrics["task_hit"] = hit
        # A restored cache need not yield a task hit on a different runner.
        # Record misses as performance outcomes; still verify artifact bytes.
        if args.phase == "cold" and hit:
            raise RuntimeError("Cold benchmark unexpectedly reused a task artifact")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    if expected is not None and digest != expected:
        raise RuntimeError("Warm artifact differs from the cold artifact")
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({"sha256": digest}) + "\n")
    metrics["artifact_sha256"] = digest
    metrics["invocation_seconds"] = round(time.perf_counter() - start, 6)
    result = ROOT / ".benchmark-results" / (args.phase + "-" + args.mode + "-" + args.target + ".json")
    result.parent.mkdir(parents=True, exist_ok=True)
    result.write_text(json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
