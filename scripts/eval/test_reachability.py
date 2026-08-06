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

Which binary matters as much as which names. This used to read the NEWEST
artifact under .zig-cache/o, and a `-Dtest-filter` build lands there too: after
one - `zig build test -Dtest-filter=foo` by hand, or the `invariants` check
right before this one in a hook that reordered - the newest artifact holds only
the tests that filter matched, and every other declared test read as "not
compiled in" (#439). tier1_test_binary.select() picks the artifact by the names
it carries instead, so the full build wins even when a filtered one is newer.

Usage:  python3 scripts/eval/test_reachability.py [--verbose]
Exit 0 when every declared test is compiled in; 1 otherwise.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import tier1_test_binary  # noqa: E402  (sibling module, not an installed package)
from tier1_test_binary import ArtifactError, declared_tests, select  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main() -> int:
    verbose = "--verbose" in sys.argv

    # A stale binary would give a false verdict in either direction, so build
    # first - unfiltered, which is also what makes the artifact we want exist -
    # and let a compile failure surface as a compile failure.
    build = subprocess.run(
        ["zig", "build", "test"], cwd=ROOT, capture_output=True, text=True
    )
    if build.returncode != 0:
        sys.stderr.write("zig build test failed; reachability not checked\n")
        sys.stderr.write(build.stderr[-2000:])
        return 1

    declared = declared_tests()
    try:
        # No filters: the full build, i.e. the artifact carrying the most
        # declared names. Raw bytes, NOT `strings` - that tool only extracts
        # ASCII runs, so every test name containing an em dash, an arrow or a
        # quote read as missing and the guard cried wolf on six live tests.
        chosen = select([], declared)
    except ArtifactError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1
    binary = chosen.path

    missing: dict[str, list[str]] = {}
    for name in chosen.missing:
        missing.setdefault(declared[name], []).append(name)

    if not chosen.was_newest:
        print(
            "  ignored a newer but filtered artifact in .zig-cache/o"
            f" ({tier1_test_binary.candidates()[0].parent.name})"
        )
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
