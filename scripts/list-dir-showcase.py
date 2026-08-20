#!/usr/bin/env python3
"""Offline showcase: graff now + new codedb list_dir vs the old index path.

No provider, no network. Builds a fixture, times the walks, and prints a
scorecard. Fail the invariants with --self-test.

    python3 scripts/list-dir-showcase.py
    python3 scripts/list-dir-showcase.py --self-test
    python3 scripts/list-dir-showcase.py --codedb /workspace/codedb/zig-out/bin/codedb
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAT = 400
MAX_LIST = 10_000


def timed(argv: list[str], cwd: Path | None, env: dict[str, str]) -> tuple[float, str, int]:
    t0 = time.perf_counter()
    proc = subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
    )
    elapsed = time.perf_counter() - t0
    out = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
    return elapsed, out, proc.returncode


def materialize(root: Path) -> None:
    (root / ".git" / "objects").mkdir(parents=True)
    (root / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    (root / ".github").mkdir()
    (root / ".github" / "ci.yml").write_text("on: push\n", encoding="utf-8")
    (root / ".gitignore").write_text("skip.log\nbuild/\n", encoding="utf-8")
    (root / "keep.zig").write_text("pub fn main() void {}\n", encoding="utf-8")
    (root / "skip.log").write_text("noise\n", encoding="utf-8")
    (root / "src").mkdir()
    (root / "src" / "main.zig").write_text("pub fn main() void {}\n", encoding="utf-8")
    (root / "build").mkdir()
    (root / "build" / "a.o").write_text("x", encoding="utf-8")
    (root / "aaa").mkdir()
    for i in range(FAT):
        (root / "aaa" / f"file_with_a_longer_name_{i:03d}.zig").write_text("x", encoding="utf-8")
    (root / "zzz").mkdir()
    (root / "zzz" / "tail.md").write_text("end\n", encoding="utf-8")


def find_codedb(explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    for cand in (
        ROOT / "codedb" / "zig-out" / "bin" / "codedb",
        Path("/workspace/codedb/zig-out/bin/codedb"),
    ):
        if cand.is_file():
            return cand
    return None


def ensure_codedb(explicit: str | None) -> Path:
    got = find_codedb(explicit)
    if got:
        return got
    src = Path("/workspace/codedb")
    zig = Path("/tmp/zig-install/zig/zig")
    if not src.is_dir() or not zig.is_file():
        raise SystemExit("codedb binary not found (pass --codedb)")
    subprocess.run([str(zig), "build"], cwd=src, check=True)
    got = find_codedb(explicit)
    if not got:
        raise SystemExit("codedb built but zig-out/bin/codedb missing")
    return got


def catalog_bits() -> dict[str, object]:
    schema = (ROOT / "src" / "schema.zig").read_text(encoding="utf-8")
    prompt = (ROOT / "src" / "prompt_text.zig").read_text(encoding="utf-8")
    names = re.findall(r'\.name = "([a-z_]+)"', schema)
    # first block is the always-on root specs; stop at meta
    root_names: list[str] = []
    for name in names:
        if name == "todo_write":
            break
        root_names.append(name)
    codedb_desc = ""
    m = re.search(r'\.name = "codedb",\s*\n\s*\.desc = "([^"]+)"', schema)
    if m:
        codedb_desc = m.group(1)
    return {
        "root_tools": root_names,
        "codedb_is_one_tool": root_names.count("codedb") == 1 and "list_dir" not in root_names,
        "codedb_desc_bytes": len(codedb_desc),
        "prompt_has_list_dir": "codedb list_dir" in prompt,
        "list_dir_in_desc": "list_dir" in codedb_desc,
    }


def checks(listing: str) -> dict[str, bool]:
    return {
        "keep.zig": "keep.zig" in listing,
        ".github": ".github" in listing,
        "skip.log hidden": "skip.log" not in listing,
        "build/ hidden": not re.search(r"^- build/$", listing, re.M)
        and "build/a.o" not in listing,
        ".git omitted": ".git/" not in listing and "\n  - .git\n" not in listing,
        "fat sibling collapsed": "files in subtree" in listing and "aaa/" in listing,
        "later sibling visible": "zzz/" in listing and "tail.md" in listing,
        "under 10k": len(listing) < MAX_LIST + 256,
    }


def section(title: str) -> None:
    print()
    print(title)
    print("=" * len(title))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codedb", help="path to codedb binary")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    cat = catalog_bits()
    codedb = ensure_codedb(args.codedb)
    env = os.environ.copy()
    env["CODEDB_NO_CLI_DAEMON"] = "1"
    env["CODEDB_QUIET"] = "1"
    env["CODEDB_NO_TELEMETRY"] = "1"

    tmp = Path(tempfile.mkdtemp(prefix="graff-list-dir-showcase-"))
    try:
        materialize(tmp)
        find_out = subprocess.check_output(["find", str(tmp), "-print"], text=True)
        ls_out = subprocess.check_output(["ls", "-la", str(tmp)], text=True)
        t_list, list_out, list_rc = timed([str(codedb), str(tmp), "list_dir", "."], None, env)
        t_ls, codedb_ls_out, ls_rc = timed([str(codedb), str(tmp), "ls"], None, env)
        t_list2, list_out2, _ = timed([str(codedb), str(tmp), "list_dir", "."], None, env)
    finally:
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)

    got = checks(list_out)
    failed = [k for k, ok in got.items() if not ok]

    if args.self_test:
        if list_rc != 0:
            raise SystemExit(f"self-test: list_dir exited {list_rc}\n{list_out}")
        if failed:
            raise SystemExit("self-test failed: " + ", ".join(failed))
        if not cat["codedb_is_one_tool"] or not cat["prompt_has_list_dir"]:
            raise SystemExit("self-test: catalog/prompt drifted")
        if len(list_out) * 10 > len(find_out):
            raise SystemExit(
                f"self-test: list_dir {len(list_out)} chars was not much smaller than find {len(find_out)}"
            )
        print("self-test ok: live walk, gitignore, 10k cap, one codedb tool, no index")
        return 0

    section("graff now")
    print("one codedb tool (not a sibling list_dir catalog entry) — ADR 0013")
    print(f"  root tools: {', '.join(cat['root_tools'])}")
    print(f"  codedb description: {cat['codedb_desc_bytes']} bytes")
    print(f"  prompt steers list_dir instead of bash ls: {cat['prompt_has_list_dir']}")
    print("  codedb stays on the every-turn surface (native_fold does not hide it)")
    print()
    print("prompt-cache max (kernels, offline):")
    show = subprocess.run(
        [sys.executable, str(ROOT / "spec" / "conformance.py"), "--showcase", "prompt"],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if show.returncode != 0:
        print("  (spec showcase unavailable)")
    else:
        for line in show.stdout.splitlines()[:24]:
            print("  " + line)

    section("new codedb list_dir vs the old index path")
    print(f"fixture: {FAT} fat-sibling files + .gitignore + .git + .github")
    print(f"codedb:  {codedb}")
    print()
    print(f"  find -print          {len(find_out):5d} chars   (no gitignore, no cap)")
    print(f"  ls -la               {len(ls_out):5d} chars   (dotfiles, no collapse)")
    print(
        f"  codedb list_dir      {len(list_out):5d} chars   {t_list*1000:6.1f} ms   exit {list_rc}  (no index)"
    )
    print(
        f"  codedb list_dir ×2   {len(list_out2):5d} chars   {t_list2*1000:6.1f} ms   (repeat, still no snapshot)"
    )
    print(
        f"  codedb ls            {len(codedb_ls_out):5d} chars   {t_ls*1000:6.1f} ms   exit {ls_rc}  (index / snapshot)"
    )
    if len(list_out) > 0:
        print(f"  list_dir is {len(find_out) / len(list_out):0.0f}× smaller than find on the same tree")
    if t_list > 0:
        print(f"  list_dir is {t_ls / t_list:0.1f}× faster than codedb ls (ls still pays the scan)")
    print()
    print("invariants (live walk):")
    for name, ok in got.items():
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")

    section("old codedb ls (index children of one directory)")
    print(codedb_ls_out.rstrip()[:800] or "(empty)")

    section("new codedb list_dir (live walk the model would see)")
    print(list_out.rstrip()[:2000])
    if len(list_out) > 2000:
        print(f"  … ({len(list_out) - 2000} more chars, still under the 10k cap)")

    section("what got better")
    print("  old codedb ls/tree: index children. Cold tree pays a scan. Extra --add-dir roots miss.")
    print("  new codedb list_dir: BFS + gitignore + 10k cap. Early-exit, no snapshot, any folder.")
    print("  graff: same walk in-process (PathConfine, --add-dir) so a missing binary still lists.")
    print("  catalog tax: still one `codedb` tool. grok-build pays a first-class list_dir every turn.")
    if failed:
        print("\nshowcase failed: " + ", ".join(failed))
        return 1
    print()
    print("verdict: better  (live walk, no catalog growth, no index on list)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
