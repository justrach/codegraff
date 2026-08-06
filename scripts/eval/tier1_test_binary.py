#!/usr/bin/env python3
"""Resolve the compiled Zig test artifact, and read the suite count off it.

`zig build test` is not a reliable narrator for either question tier 1 asks it
(#439):

  * The count. On zig 0.17 a fully cached run prints "Build Summary: 4/4 steps
    succeeded" and stops - there is no "N/N tests passed" line, because the run
    step never re-ran. The shell's sed came back empty and the tests check
    FAILED a suite that was green. The artifact still knows: a test binary
    invoked with no arguments prints "All N tests passed." as its last line,
    cached build or not, and running it re-proves the suite besides.
  * Which binary. .zig-cache/o/*/test accumulates one artifact per distinct
    build, and every -Dtest-filter build lands there too. Taking the newest, as
    the reachability check used to, reads a FILTERED binary whenever the last
    build was filtered - and then reports the ~950 tests it legitimately does
    not contain as "not compiled in".

So selection is by content, never by mtime. Every `test "name"` in src/*.zig is
a byte string inside the binary that compiled it, and -Dtest-filter drops the
tests it does not match at COMPILE time, names and all. The build we want is the
one whose declared-name set matches what its filters select: no filters means
every declared name, and the tier-1 floor build (a filter matching nothing)
means none of them. mtime only breaks ties.

  resolve [--filter TEXT]...  print the artifact path for that build
  count   [--filter TEXT]...  run that artifact and print how many tests it holds

Both exit non-zero with a reason on stderr rather than guess. Neither builds:
the caller runs `zig build test` (with the same filters) first, so a compile
error surfaces as a compile error.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "src"
CACHE = ROOT / ".zig-cache" / "o"

TEST_NAME = re.compile(r'^test "((?:[^"\\]|\\.)*)"', re.M)
ALL_PASSED = re.compile(r"^All (\d+) tests passed\.$", re.M)
MIXED = re.compile(r"^(\d+) passed; (\d+) skipped; (\d+) failed\.$", re.M)


class ArtifactError(Exception):
    """No usable test artifact, or one that would not say how many tests it holds."""


def declared_tests() -> dict[str, str]:
    """Every `test "name"` in src/*.zig, mapped to the file that declares it."""
    out: dict[str, str] = {}
    for path in sorted(SRC.glob("*.zig")):
        for match in TEST_NAME.finditer(path.read_text(encoding="utf-8")):
            # The source carries Zig escapes; the binary carries the resolved
            # bytes. Unescape so a name containing a quote still matches.
            name = match.group(1).replace('\\"', '"').replace("\\\\", "\\")
            out[name] = path.name
    return out


class Selection:
    """One candidate artifact, scored against the build we asked for."""

    def __init__(self, path: pathlib.Path, present: set[str], expected: set[str]):
        self.path = path
        self.present = present
        self.expected = expected
        self.considered = 1
        self.was_newest = True

    @property
    def missing(self) -> set[str]:
        """Names this build should carry and does not."""
        return self.expected - self.present

    @property
    def extra(self) -> set[str]:
        """Names it carries that the filters did not ask for."""
        return self.present - self.expected

    def describe(self) -> str:
        return (
            f"{self.path.parent.name} ({len(self.present)} of {len(self.expected)}"
            f" expected test names; {self.considered} artifact(s) in .zig-cache/o)"
        )


def candidates() -> list[pathlib.Path]:
    """Every compiled test artifact, newest first."""
    found = [p for p in CACHE.glob("*/test") if p.is_file()]
    return sorted(found, key=lambda p: p.stat().st_mtime, reverse=True)


def select(filters: list[str], declared: dict[str, str] | None = None) -> Selection:
    """The artifact built with exactly these -Dtest-filter values (none = full).

    Zig's filters are substring matches on the test name, so the set of declared
    names a filtered build keeps is computable from the source alone. Rank every
    candidate by how far it is from that set - missing names first, then names it
    should not have - and the full build wins the unfiltered question even when a
    filtered build is newer.
    """
    if declared is None:
        declared = declared_tests()
    expected = {n for n in declared if not filters or any(f in n for f in filters)}

    ranked: list[Selection] = []
    # candidates() is newest first and sort() below is stable, so ties stay in
    # that order and the newest equally-good artifact wins.
    for path in candidates():
        blob = path.read_bytes()
        present = {n for n in declared if n.encode("utf-8") in blob}
        ranked.append(Selection(path, present, expected))
    if not ranked:
        raise ArtifactError(
            "no compiled test binary under .zig-cache/o - run `zig build test` first"
        )

    newest = ranked[0].path
    ranked.sort(key=lambda s: (len(s.missing), len(s.extra)))
    best = ranked[0]
    best.considered = len(ranked)
    best.was_newest = best.path == newest
    return best


def artifact_count(path: pathlib.Path) -> tuple[int, str]:
    """Run the artifact and read its own tally. Raises if it does not pass."""
    proc = subprocess.run(
        [str(path)], cwd=ROOT, capture_output=True, text=True, errors="replace"
    )
    blob = proc.stdout + proc.stderr
    passed = ALL_PASSED.search(blob)
    if passed and proc.returncode == 0:
        return int(passed.group(1)), blob
    mixed = MIXED.search(blob)
    if mixed:
        ok, skipped, failed = (int(g) for g in mixed.groups())
        if failed == 0 and proc.returncode == 0:
            return ok + skipped, blob
        raise ArtifactError(
            f"{path} reported {failed} failing test(s):\n" + "\n".join(blob.splitlines()[-12:])
        )
    raise ArtifactError(
        f"{path} exited {proc.returncode} without a test tally:\n"
        + "\n".join(blob.splitlines()[-12:])
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("resolve", "count"):
        cmd = sub.add_parser(name)
        cmd.add_argument(
            "--filter",
            action="append",
            default=[],
            help="a -Dtest-filter value the build used (repeatable; none = the full build)",
        )
    args = parser.parse_args()

    try:
        chosen = select(args.filter)
    except ArtifactError as exc:
        print(f"  {exc}", file=sys.stderr)
        return 1

    if chosen.missing and not args.filter:
        # Not fatal here: `reach` is the check that judges missing names. Say it
        # out loud so a thin artifact never passes for the full one in silence.
        print(
            f"  note: {chosen.describe()} is missing {len(chosen.missing)} declared"
            " test name(s) - it is still the fullest artifact available",
            file=sys.stderr,
        )
    if not chosen.was_newest:
        print(
            "  note: the newest artifact in .zig-cache/o is a different build"
            f" (its -Dtest-filter set differs); using {chosen.path.parent.name}",
            file=sys.stderr,
        )

    if args.cmd == "resolve":
        print(chosen.path)
        return 0

    try:
        count, _ = artifact_count(chosen.path)
    except ArtifactError as exc:
        print(f"  {exc}", file=sys.stderr)
        return 1
    print(count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
