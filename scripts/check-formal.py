#!/usr/bin/env python3
"""Run bounded TLC lifecycle models and verify their negative controls."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FORMAL = ROOT / "formal"
JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
TIMEOUT_SECONDS = 120
CASES = (
    ("EffortSelection.tla", "EffortSelection.cfg", None),
    ("EffortSelection.tla", "EffortSelectionStale.cfg", "SelectedOriginIsCurrent"),
    ("AsyncTools.tla", "AsyncTools.cfg", None),
    ("AsyncTools.tla", "AsyncToolsNoJoin.cfg", "JoinedBeforeNextRequest"),
    ("AsyncTools.tla", "AsyncToolsNoDedup.cfg", "AtMostOnceExecution"),
    ("AsyncTools.tla", "AsyncToolsNoBarrier.cfg", "NoLateAdmission"),
)


def run_case(java: str, jar: Path, module: str, config: str, expected: str | None) -> None:
    with tempfile.TemporaryDirectory(prefix="codegraff-tlc-") as scratch:
        metadata = Path(scratch) / "state"
        metadata.mkdir()
        command = [
            java,
            "-Xmx512m",
            "-XX:+UseParallelGC",
            "-cp",
            str(jar),
            "tlc2.TLC",
            "-workers",
            "1",
            "-deadlock",
            "-coverage",
            "1",
            "-metadir",
            str(metadata),
            "-config",
            config,
            module,
        ]
        try:
            result = subprocess.run(
                command,
                cwd=FORMAL,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"{config}: TLC exceeded {TIMEOUT_SECONDS}s") from exc

    output = result.stdout + result.stderr
    if expected is None:
        if result.returncode != 0 or "Model checking completed. No error has been found." not in output:
            raise RuntimeError(f"{config}: expected a complete safe model check\n{output[-2000:]}")
    else:
        needle = re.compile(rf"^Error: Invariant {re.escape(expected)} is violated\.$", re.MULTILINE)
        if result.returncode == 0 or needle.search(output) is None:
            raise RuntimeError(f"{config}: expected counterexample for {expected}\n{output[-2000:]}")

    totals = re.findall(r"(\d+) states generated, (\d+) distinct states found", output)
    counts = f"{totals[-1][1]} distinct states" if totals else "counterexample found"
    outcome = "PASS" if expected is None else f"EXPECTED {expected}"
    print(f"{config}: {outcome}; {counts}")


def main() -> int:
    java = os.environ.get("JAVA", "java")
    jar_name = os.environ.get("TLA2TOOLS")
    if not jar_name:
        print("Set TLA2TOOLS to the checked tla2tools.jar path.", file=sys.stderr)
        return 2
    jar = Path(jar_name).expanduser().resolve()
    if not jar.is_file():
        print(f"TLA2TOOLS is not a file: {jar}", file=sys.stderr)
        return 2
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JAR_SHA256:
        print("TLA2TOOLS does not match the checked v1.7.4 jar hash.", file=sys.stderr)
        return 2
    try:
        for module, config, expected in CASES:
            run_case(java, jar, module, config, expected)
    except (OSError, RuntimeError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
