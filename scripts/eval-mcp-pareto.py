#!/usr/bin/env python3
"""Pareto front for the Linear MCP bench.

Minimize wall_s, tok_in, tok_calls among passing runs. A point is on the
front if nothing else is ≤ on all three and < on at least one.

  zig build -Doptimize=ReleaseSafe
  python3 scripts/eval-mcp-pareto.py            # live A,H,J,K + history
  python3 scripts/eval-mcp-pareto.py --history  # print front from seeded + json only

Seeded history is ADR 0029's SuperGrok grok-4.6 reps (2026-08-25).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EVALS = REPO / "graff-evals"
SHAPES = REPO / "scripts" / "eval-mcp-shapes.py"

# wall, tok_in, calls — lower is better. pass required.
HISTORY = [
    {"id": "A-r1", "wall": 36.7, "tok_in": 167692, "calls": 10, "ok": True, "note": "--old structured"},
    {"id": "A-r2", "wall": 36.4, "tok_in": 145497, "calls": 9, "ok": True, "note": "--old structured"},
    {"id": "B", "wall": 43.3, "tok_in": 179822, "calls": 11, "ok": True, "note": "rlm, MCP structured-only"},
    {"id": "C", "wall": 56.7, "tok_in": 147948, "calls": 13, "ok": True, "note": "rlm+MCP cold + each()"},
    {"id": "D-r1", "wall": 41.1, "tok_in": 107213, "calls": 10, "ok": True, "note": "rlm+MCP warm + each()"},
    {"id": "D-r2", "wall": 60.5, "tok_in": 158769, "calls": 11, "ok": True, "note": "rlm+MCP warm + each()"},
    {"id": "E1", "wall": 37.5, "tok_in": 168164, "calls": 11, "ok": True, "note": "sidecar"},
    {"id": "E2", "wall": 75.5, "tok_in": 149156, "calls": 18, "ok": True, "note": "two siblings"},
    {"id": "F", "wall": 220.1, "tok_in": 462379, "calls": 29, "ok": True, "note": "each() + quiet print"},
    {"id": "G", "wall": 155.6, "tok_in": 279981, "calls": 21, "ok": True, "note": "quiet + warm"},
    {"id": "H", "wall": 28.0, "tok_in": 112073, "calls": 7, "ok": True, "note": "no each() recipe"},
    {"id": "I", "wall": 31.1, "tok_in": 107284, "calls": 7, "ok": True, "note": "no recipe + warm"},
]


def dominates(a: dict, b: dict) -> bool:
    """a dominates b: ≤ on every objective and < on one."""
    aw, at, ac = a["wall"], a["tok_in"], a["calls"]
    bw, bt, bc = b["wall"], b["tok_in"], b["calls"]
    le = aw <= bw and at <= bt and ac <= bc
    lt = aw < bw or at < bt or ac < bc
    return le and lt


def frontier(points: list[dict]) -> list[dict]:
    ok = [p for p in points if p.get("ok")]
    front = []
    for p in ok:
        if any(dominates(q, p) for q in ok if q is not p):
            continue
        front.append(p)
    return sorted(front, key=lambda p: (p["wall"], p["tok_in"], p["calls"]))


def live_row(variant: str) -> dict | None:
    proc = subprocess.run(
        [sys.executable, str(SHAPES), "--only", variant, "--model", "grok-4.6"],
        cwd=REPO,
        check=False,
    )
    if proc.returncode != 0:
        return None
    path = EVALS / "results" / "mcp-shapes-summary.json"
    if not path.exists():
        return None
    rows = json.loads(path.read_text())
    if not rows:
        return None
    r = rows[0]
    return {
        "id": f"{variant}-live",
        "wall": float(r.get("wall_s") or 0),
        "tok_in": int(r.get("tok_in") or 0),
        "calls": int(r.get("tok_calls") or 0),
        "ok": bool(r.get("outcome_ok")),
        "note": r.get("label") or variant,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--history", action="store_true", help="do not drive a provider")
    ap.add_argument("--only", default="A,H,J,K", help="live variant ids")
    args = ap.parse_args()

    points = [dict(p) for p in HISTORY]
    if not args.history:
        oauth = Path.home() / ".xai/credentials/graff-oauth.json"
        if not oauth.exists():
            print("no SuperGrok OAuth — use --history", file=sys.stderr)
            return 2
        for vid in [x.strip().upper() for x in args.only.split(",") if x.strip()]:
            print(f"== live {vid} ==", flush=True)
            row = live_row(vid)
            if row:
                points.append(row)
                print(json.dumps(row), flush=True)

    front = frontier(points)
    front_ids = {p["id"] for p in front}
    print("\nall points (pass only); * = Pareto front on wall / tok_in / calls\n")
    print(f"{'id':<10} {'front':<5} {'wall':>7} {'in':>8} {'calls':>5}  note")
    for p in sorted(points, key=lambda x: (not x.get("ok"), x["wall"], x["tok_in"])):
        if not p.get("ok"):
            continue
        mark = "*" if p["id"] in front_ids else " "
        print(f"{p['id']:<10} {mark:<5} {p['wall']:7.1f} {p['tok_in']:8} {p['calls']:5}  {p['note']}")
    print("\nfrontier:")
    for p in front:
        print(f"  {p['id']}: {p['wall']:.1f}s / {p['tok_in']} in / {p['calls']} calls — {p['note']}")
    out = EVALS / "results" / "mcp-pareto.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"points": points, "frontier": front}, indent=2) + "\n")
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
