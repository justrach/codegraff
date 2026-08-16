#!/usr/bin/env python3
"""Score the last N git version tags against the Lean kernels.

A release *hits* a kernel if it touched that kernel's implementation
files. TUI-only releases are out of spec by design. Re-run after a
release cut to see whether the corpus still covers what versions occupy.
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict

KERNELS = {
    "catalog": ("src/schema.zig", "src/tool_gates.zig", "src/no_local_tools.zig"),
    "transport": ("src/agent_ws.zig", "src/transport_gate.zig", "src/agent_request.zig"),
    "provider": ("src/provider.zig",),
    "goal": ("src/goal_state.zig", "src/goal_todo.zig", "src/goal_flow.zig"),
    "path": ("src/harness_policy.zig", "src/worktree_lease.zig"),
    "shape": ("src/escalation.zig", "src/shapes.zig", "src/route_policy.zig"),
    "score": ("src/scoring.zig", "src/pipeline_score.zig", "src/shapes.zig"),
    "bash": ("src/harness_policy.zig", "src/approvals.zig"),
}


def tags(n: int = 40) -> list[str]:
    raw = subprocess.check_output(["git", "tag", "--sort=v:refname"], text=True)
    found = [t for t in raw.split() if re.match(r"v0\.0\.\d+$", t)]
    return found[-(n + 1) :]


def changed(a: str, b: str) -> list[str]:
    out = subprocess.check_output(["git", "diff", "--name-only", f"{a}..{b}"], text=True)
    return [p for p in out.splitlines() if p]


def main() -> int:
    n = 40
    if len(sys.argv) > 1:
        n = int(sys.argv[1])
    ts = tags(n)
    hits: dict[str, int] = defaultdict(int)
    spec_hit = tui_only = other = 0
    print(f"{'ver':<10} {'cat':>3} {'ws':>3} {'prov':>4} {'goal':>4} {'path':>4} {'shp':>3} {'sc':>3}  TUI  hit")
    for a, b in zip(ts, ts[1:]):
        files = changed(a, b)
        flagged = [k for k, paths in KERNELS.items() if any(f in paths for f in files)]
        for k in flagged:
            hits[k] += 1
        tui = any(f.startswith("TUI/") for f in files)
        if flagged:
            spec_hit += 1
            label = ",".join(flagged)
        elif tui:
            tui_only += 1
            label = "TUI-only"
        else:
            other += 1
            label = "other"
        cells = {k: ("Y" if k in flagged else ".") for k in KERNELS}
        print(
            f"{b:<10} {cells['catalog']:>3} {cells['transport']:>3} "
            f"{cells['provider']:>4} {cells['goal']:>4} {cells['path']:>4} "
            f"{cells['shape']:>3} {cells['score']:>3}  {'Y' if tui else '.':>3}  {label}"
        )
    total = spec_hit + tui_only + other
    print()
    print(
        f"{total} versions: {spec_hit} hit a kernel, {tui_only} TUI-only, {other} other"
    )
    print("kernel hits:", dict(hits))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
