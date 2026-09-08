#!/usr/bin/env python3
"""Grade one named Zig test from `zig build test --summary all`.

Zig 0.17's -Dtest-filter only runs anonymous `test {}` hooks (45 always-green
imports). The public/hidden live checks parse the full suite instead.
Exit 0 iff the compile ran and `name` is not in the failed/crashed set.
"""
from __future__ import annotations

import subprocess
import sys


def failed_names(output: str) -> list[str]:
    names = []
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("error: '"):
            continue
        rest = line[len("error: '"):]
        end = rest.find("'")
        if end == -1:
            continue
        names.append(rest[:end])
    return names


def named_ok(output: str, name: str) -> bool:
    needle = name
    for failed in failed_names(output):
        if needle in failed:
            return False
    if "error: failed to open configuration" in output:
        return False
    if "the following maker command exited" in output and "run test" not in output:
        # compile / setup failure, not a test assertion
        if "compile" in output and "success" not in output.split("compile")[-1][:80]:
            return False
    return True


def run(cwd: str, name: str, timeout: int = 300) -> int:
    proc = subprocess.run(
        ["zig", "build", "test", "--summary", "all"],
        cwd=cwd, capture_output=True, text=True, timeout=timeout,
    )
    out = (proc.stdout or "") + "\n" + (proc.stderr or "")
    sys.stdout.write(out[-4000:])
    if "error: failed to open configuration" in out:
        return 2
    if "compile test" in out and "error:" in out and "test." not in "".join(failed_names(out)):
        # compile error with no named test failures
        if proc.returncode != 0 and not failed_names(out):
            return 2
    ok = named_ok(out, name)
    return 0 if ok else 1


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: named_check.py <name-substring> [cwd]")
    name = sys.argv[1]
    cwd = sys.argv[2] if len(sys.argv) > 2 else "."
    raise SystemExit(run(cwd, name))


if __name__ == "__main__":
    main()
