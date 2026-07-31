#!/usr/bin/env python3
"""Fail if any declared Zig test is not actually compiled into the test binary.

Zig only compiles a `test` block when its file is reachable from the test root.
A module nothing imports has its tests SILENTLY SKIPPED: they sit in the source
reading as coverage and never run. That is not hypothetical - 12 files and 37
tests were in exactly that state, including the whole promotion ladder in
learn_tournament.zig, and one of them was already stale and failing the moment
it was wired back in.

Why this check and not the previous one: tier1_invariants.py modelled
reachability as a TEXTUAL `@import` graph over the source. That over-approximates
what Zig actually analyses, so it printed "every test file is reachable from the
test root" and exited 0 while 37 tests were dead. This compares two ground
truths instead - the names declared in src/*.zig, and the names present in the
compiled binary - so it cannot be fooled by an import Zig never follows.

Usage:  python3 scripts/eval/test_reachability.py [--verbose]
Exit 0 when every declared test is compiled in; 1 otherwise.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "src"
CACHE = ROOT / ".zig-cache" / "o"

TEST_NAME = re.compile(r'^test "((?:[^"\\]|\\.)*)"', re.M)


def declared_tests() -> dict[str, str]:
    """Every `test "name"` in src/*.zig, mapped to its file."""
    out: dict[str, str] = {}
    for path in sorted(SRC.glob("*.zig")):
        for match in TEST_NAME.finditer(path.read_text(encoding="utf-8")):
            # The source carries Zig escapes; the binary carries the resolved
            # bytes. Unescape so a name containing a quote still matches.
            name = match.group(1).replace('\\"', '"').replace("\\\\", "\\")
            out[name] = path.name
    return out


def newest_test_binary() -> pathlib.Path | None:
    candidates = [p for p in CACHE.glob("*/test") if p.is_file()]
    return max(candidates, key=lambda p: p.stat().st_mtime) if candidates else None


def main() -> int:
    verbose = "--verbose" in sys.argv

    # A stale binary would give a false verdict in either direction, so build
    # first and let a compile failure surface as a compile failure.
    build = subprocess.run(
        ["zig", "build", "test"], cwd=ROOT, capture_output=True, text=True
    )
    if build.returncode != 0:
        sys.stderr.write("zig build test failed; reachability not checked\n")
        sys.stderr.write(build.stderr[-2000:])
        return 1

    binary = newest_test_binary()
    if binary is None:
        sys.stderr.write("no compiled test binary found under .zig-cache/o\n")
        return 1

    # Raw bytes, NOT `strings`: that tool only extracts ASCII runs, so every
    # test name containing an em dash, an arrow or a quote read as missing and
    # the guard cried wolf on six perfectly live tests. Searching the bytes for
    # the UTF-8 encoding of each name has no such blind spot.
    blob = binary.read_bytes()

    declared = declared_tests()
    missing: dict[str, list[str]] = {}
    for name, file in declared.items():
        if name.encode("utf-8") not in blob:
            missing.setdefault(file, []).append(name)

    if not missing:
        print(f"  all {len(declared)} declared tests are compiled in ({binary.parent.name})")
        return 0

    total = sum(len(v) for v in missing.values())
    print(f"  {total} declared test(s) in {len(missing)} file(s) are NOT compiled in:")
    for file in sorted(missing):
        print(f"    {file}  ({len(missing[file])})")
        if verbose:
            for name in missing[file]:
                print(f"        {name}")
    print("  add a reference in src/test_hooks.zig so Zig analyses the module")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
