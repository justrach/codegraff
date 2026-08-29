#!/usr/bin/env python3
"""Static and count-based halves of the tier-1 eval set.

Two things `zig build test` alone cannot tell you:

  1. Whether a module's tests are *reachable* from the test root. Zig only runs
     the tests in files the root pulls in; a split-out module that nobody
     references compiles to nothing and the suite still reports green. That is
     how src/main_tests.zig sat dead for months.
  2. Whether the invariants this repo actually regressed on are still covered.
     A named test can be deleted, renamed, or orphaned and the total barely
     moves.

Subcommands (all offline, all under a second):

  static              import-graph reachability + required-invariant presence
  filters             print one -Dtest-filter value per line, for the shell
  count --observed N  the total suite count may grow, never shrink
  invariants --observed N   the filtered run must have run exactly the required set
  invariants --scan         same check against the unfiltered test artifact (#641)

`count` exits 3, not 1, when the suite has run far enough ahead of the baseline
that the floor no longer guards anything (#439: it sat 350 behind). That is a
warning the caller surfaces, never a failure - the baseline is a floor, and only
a human bumps it, in the commit that earned the tests.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO / "scripts" / "eval" / "tier1-manifest.json"
IMPORT = re.compile(r'@import\("([^"]+\.zig)"\)')
TEST_DECL = re.compile(r'(?m)^test[ {]')
TEST_NAME = re.compile(r'(?m)^test "((?:[^"\\]|\\.)*)"')

# `count` exit code for "green, but the baseline is far enough behind the real
# suite that it guards nothing". Kept out of 0/1 so the shell can tell a warning
# from a pass and from a failure. scripts/eval-tier1.sh reads it.
RATCHET_STALLED = 3
DEFAULT_SLACK = 25


def load_manifest() -> dict:
    try:
        return json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.exit(f"tier1: cannot read {MANIFEST}: {exc}")


def reachable_files(roots: list[str]) -> set[pathlib.Path]:
    """Every .zig file the test roots pull in, transitively."""
    seen: set[pathlib.Path] = set()
    stack = [REPO / root for root in roots]
    while stack:
        current = stack.pop().resolve()
        if current in seen or not current.is_file():
            continue
        seen.add(current)
        text = current.read_text(encoding="utf-8", errors="replace")
        for target in IMPORT.findall(text):
            stack.append(current.parent / target)
    return seen


def files_with_tests() -> list[pathlib.Path]:
    found = []
    for path in sorted((REPO / "src").rglob("*.zig")):
        if TEST_DECL.search(path.read_text(encoding="utf-8", errors="replace")):
            found.append(path.resolve())
    return found


def all_test_names() -> dict[str, list[pathlib.Path]]:
    names: dict[str, list[pathlib.Path]] = {}
    for path in sorted((REPO / "src").rglob("*.zig")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for name in TEST_NAME.findall(text):
            names.setdefault(name, []).append(path)
    return names


def check_static(manifest: dict) -> list[str]:
    failures: list[str] = []
    reachable = reachable_files(manifest["test_roots"])

    orphans = [p for p in files_with_tests() if p not in reachable]
    if orphans:
        listing = "\n".join(f"      src/{p.relative_to(REPO / 'src')}" for p in orphans)
        failures.append(
            "reachability: these files declare tests that never run - nothing in\n"
            f"    {', '.join(manifest['test_roots'])} imports them:\n{listing}\n"
            "      fix: reference the module from src/main.zig's `test {}` block\n"
            "           (`_ = @import(\"x.zig\");`), or delete the dead file."
        )

    known = all_test_names()
    required = manifest["required_invariants"]
    for entry in required:
        name = entry["test"]
        where = known.get(name, [])
        if not where:
            failures.append(
                f"invariant {entry['id']}: no test named\n      \"{name}\"\n"
                f"    it guards: {entry['why']}\n"
                "      fix: restore the test, or drop the entry from"
                " scripts/eval/tier1-manifest.json with a reason."
            )
        elif len(where) > 1:
            listing = ", ".join(str(p.relative_to(REPO)) for p in where)
            failures.append(
                f"invariant {entry['id']}: the name is declared {len(where)} times"
                f" ({listing});\n    tier 1 counts filter hits, so the name must be unique."
            )

    # The filtered run below counts hits, so no required name may be a prefix or
    # substring of another test's name - that would inflate the count and hide a
    # genuinely missing invariant.
    for entry in required:
        name = entry["test"]
        collisions = [other for other in known if other != name and name in other]
        if collisions:
            failures.append(
                f"invariant {entry['id']}: its name is a substring of"
                f" {len(collisions)} other test name(s), e.g.\n      \"{collisions[0]}\"\n"
                "    pick a distinct name so the -Dtest-filter hit count stays exact."
            )
    return failures


def docs_only(paths: list[str], manifest: dict) -> bool:
    patterns = manifest.get("docs_only_paths", [])
    if not paths:
        return True
    return all(any(fnmatch.fnmatch(p, pat) for pat in patterns) for p in paths)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("static")
    sub.add_parser("filters")
    sub.add_parser("list")
    count = sub.add_parser("count")
    count.add_argument("--observed", type=int, required=True)
    inv = sub.add_parser("invariants")
    inv.add_argument("--observed", type=int, default=None)
    inv.add_argument(
        "--scan",
        action="store_true",
        help="count required names in the unfiltered test artifact (no recompile)",
    )
    skip = sub.add_parser("docs-only")
    skip.add_argument("paths", nargs="*")
    args = parser.parse_args()
    manifest = load_manifest()

    if args.cmd == "filters":
        for entry in manifest["required_invariants"]:
            print(entry["test"])
        return

    if args.cmd == "list":
        for entry in manifest["required_invariants"]:
            print(f"      {entry['id']}: {entry['test']}")
        return

    if args.cmd == "docs-only":
        sys.exit(0 if docs_only(args.paths, manifest) else 1)

    if args.cmd == "static":
        failures = check_static(manifest)
        for failure in failures:
            print(f"  FAIL {failure}", file=sys.stderr)
        if failures:
            sys.exit(1)
        print(
            f"  every test file is reachable from the test root;"
            f" all {len(manifest['required_invariants'])} named invariants present"
        )
        return

    if args.cmd == "count":
        baseline = int(manifest["test_count_baseline"])
        slack = int(manifest.get("test_count_slack", DEFAULT_SLACK))
        if args.observed < baseline:
            print(
                f"  FAIL test count dropped: {args.observed} ran, baseline is {baseline}.\n"
                "    Tests do not disappear on their own. Either a module stopped being\n"
                "    referenced from src/main.zig's `test {}` block (its tests now compile\n"
                "    to nothing and the suite still reports green), or tests were removed.\n"
                "      fix: restore them, or lower test_count_baseline in\n"
                "           scripts/eval/tier1-manifest.json in the same commit, with a reason.",
                file=sys.stderr,
            )
            sys.exit(1)
        drift = args.observed - baseline
        if drift > slack:
            # Never raise it here: a floor that moves on its own is not a floor,
            # and the number belongs in the same commit as the tests that earned
            # it. But say it loudly, because the alternative is what #439 found -
            # a baseline 350 behind, guarding nothing, for months.
            print(
                f"  WARN the ratchet has stalled: {args.observed} tests ran but"
                f" test_count_baseline is {baseline}, {drift} behind (slack {slack}).\n"
                "    A floor that far below the suite would not notice a whole module\n"
                "    falling out of the test root.\n"
                f"      fix: set test_count_baseline to {args.observed} in\n"
                "           scripts/eval/tier1-manifest.json and commit it.",
                file=sys.stderr,
            )
            sys.exit(RATCHET_STALLED)
        if drift:
            print(
                f"  {args.observed} tests ran (baseline {baseline}) - "
                "bump test_count_baseline in scripts/eval/tier1-manifest.json to ratchet it up"
            )
        else:
            print(f"  {args.observed} tests ran, matching the baseline")
        return

    if args.cmd == "invariants":
        expected = len(manifest["required_invariants"])
        if args.scan:
            # Import sibling: same directory as this file.
            sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
            import tier1_test_binary  # noqa: E402

            try:
                chosen = tier1_test_binary.select([])
            except tier1_test_binary.ArtifactError as exc:
                print(f"  FAIL {exc}", file=sys.stderr)
                sys.exit(1)
            required = [entry["test"] for entry in manifest["required_invariants"]]
            missing = [name for name in required if name not in chosen.present]
            if missing:
                print(
                    f"  FAIL {len(required) - len(missing)} of {expected} named"
                    " invariants present in the unfiltered test artifact.\n"
                    f"    missing: {missing[0]!r}",
                    file=sys.stderr,
                )
                sys.exit(1)
            print(f"  all {expected} named goal/loop/todo invariants compiled in")
            return
        if args.observed is None:
            print("  FAIL invariants: pass --observed N or --scan", file=sys.stderr)
            sys.exit(1)
        if args.observed != expected:
            print(
                f"  FAIL {args.observed} of {expected} named invariants ran under"
                " -Dtest-filter.\n"
                "    Either one of them is gone from the source, or it is still there and\n"
                "    its module is no longer pulled into the test root - in which case it\n"
                "    compiles to nothing and the suite still reports green.\n"
                "      fix: `scripts/eval-tier1.sh --only reach` names any invariant that\n"
                "           vanished from the source. If that passes, the test exists but\n"
                "           never runs: reference its module from src/main.zig's `test {}`\n"
                "           block (`_ = @import(\"x.zig\");`).",
                file=sys.stderr,
            )
            sys.exit(1)
        print(f"  all {expected} named goal/loop/todo invariants ran")


if __name__ == "__main__":
    main()
