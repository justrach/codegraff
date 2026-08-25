#!/usr/bin/env python3
"""Run the Blacksmith-shaped MCP A/B (variants A–E) and print the table.

  zig build -Doptimize=ReleaseSafe
  python3 scripts/eval-mcp-shapes.py
  python3 scripts/eval-mcp-shapes.py --mock   # scripted model, no provider

Records pass/fail, wall, RSS, tokens, API calls, and whether the model
retried or guessed wrong MCP fields (from .graff/traces).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EVALS = REPO / "graff-evals"
WRONG = re.compile(
    r"unknown|missing required|needs id|unsupported statement|not loaded|GRAFF_RLM_MCP|bad args|issue_id|issueId",
    re.I,
)


VARIANTS = [
    {
        "id": "A",
        "harness": "graff-dev-old-nolean",
        "task": "linear-issues",
        "label": "--old structured MCP only",
    },
    {
        "id": "B",
        "harness": "graff-dev-rlm-struct",
        "task": "linear-issues",
        "label": "default rlm, MCP structured-only",
    },
    {
        "id": "C",
        "harness": "graff-dev-nolean",
        "task": "linear-issues",
        "label": "rlm + MCP host, cold",
    },
    {
        "id": "D",
        "harness": "graff-dev-nolean",
        "task": "linear-warm",
        "label": "rlm + MCP host, warm shapes",
    },
    {
        "id": "E1",
        "harness": "graff-dev-nolean",
        "task": "linear-sidecar",
        "label": "C + sidecar summarize subagent",
    },
    {
        "id": "E2",
        "harness": "graff-dev-nolean",
        "task": "linear-split",
        "label": "two sibling subagents split 8 issues",
    },
    {
        "id": "F",
        "harness": "graff-dev-nolean",
        "task": "linear-quiet",
        "label": "rlm+MCP host, cold, no fat print()",
    },
    {
        "id": "G",
        "harness": "graff-dev-nolean",
        "task": "linear-quiet-warm",
        "label": "rlm+MCP host, warm, no fat print()",
    },
    {
        "id": "H",
        "harness": "graff-dev-nolean",
        "task": "linear-nohint",
        "label": "rlm+MCP host, cold, no each() recipe",
    },
    {
        "id": "I",
        "harness": "graff-dev-nolean",
        "task": "linear-nohint-warm",
        "label": "rlm+MCP host, warm, no each() recipe",
    },
    {
        "id": "J",
        "harness": "graff-dev-nolean",
        "task": "linear-reduce",
        "label": "rlm+MCP host, cold, len/project recipe",
    },
    {
        "id": "K",
        "harness": "graff-dev-nolean",
        "task": "linear-reduce-warm",
        "label": "rlm+MCP host, warm, len/project recipe",
    },
    {
        "id": "L",
        "harness": "graff-dev-nolean",
        "task": "linear-nohint-warm",
        "label": "learnt slim + playbook, no each() hint, warm",
    },
    {
        "id": "M",
        "harness": "graff-dev-nolean",
        "task": "linear-warm",
        "label": "learnt slim + each() hint, warm",
    },
    {
        "id": "N",
        "harness": "graff-dev-nolean",
        "task": "linear-nohint",
        "label": "learnt slim mid-run, no each() hint, cold",
    },
    {
        "id": "O",
        "harness": "graff-dev-nolean",
        "task": "linear-quiet",
        "label": "learnt slim, quiet print, cold",
    },
    {
        "id": "P",
        "harness": "graff-dev-nolean",
        "task": "linear-reduce",
        "label": "learnt slim + len/project recipe, cold",
    },
    {
        "id": "Q",
        "harness": "graff-dev-nolean",
        "task": "linear-reduce-warm",
        "label": "learnt slim + len/project recipe, warm",
    },
]


def parse_traces(sandbox: Path) -> dict:
    retried = False
    wrong = False
    mcp_calls = 0
    rlm_calls = 0
    for path in sandbox.glob(".graff/traces/*.jsonl"):
        for line in path.read_text().splitlines():
            if not line.startswith("{"):
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = ev.get("name") or ev.get("tool") or ""
            text = str(ev.get("text") or ev.get("output") or "")
            if name.startswith("mcp__") or name in {"list_issues", "list_comments"}:
                mcp_calls += 1
            if name == "rlm":
                rlm_calls += 1
            if ev.get("is_error") or ev.get("error"):
                if WRONG.search(text) or WRONG.search(name):
                    wrong = True
                    retried = True
            if "load_tool_schemas first" in text or "not loaded" in text:
                retried = True
                wrong = True
    return {"retried": retried, "wrong_fields": wrong, "mcp_calls": mcp_calls, "rlm_calls": rlm_calls}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mock", action="store_true", help="skip live provider (print harness plan only)")
    ap.add_argument("--model", default="grok-4.6")
    ap.add_argument("--only", default="", help="comma-separated variant ids (A,D,F,...)")
    args = ap.parse_args()

    wanted = {x.strip().upper() for x in args.only.split(",") if x.strip()}
    variants = [v for v in VARIANTS if not wanted or v["id"] in wanted]

    if args.mock:
        print("mock: not driving a provider. Unit tests cover dispatch/shapes; live A/B needs SuperGrok.")
        for v in variants:
            print(f"  {v['id']}  {v['harness']}  {v['task']}  {v['label']}")
        return 0

    oauth = Path.home() / ".xai/credentials/graff-oauth.json"
    if not oauth.exists():
        print("no SuperGrok OAuth at ~/.xai/credentials/graff-oauth.json — pass --mock or sign in", file=sys.stderr)
        return 2

    rows = []
    for v in variants:
        cmd = [
            sys.executable,
            str(EVALS / "run.py"),
            "--suite",
            "mcp",
            "--task",
            v["task"],
            "--harness",
            v["harness"],
            "--model",
            args.model,
            "--reps",
            "1",
        ]
        print(f"== {v['id']} {v['label']} ==", flush=True)
        subprocess.run(cmd, cwd=EVALS, check=False)
        # newest result line for this harness/task
        results = sorted((EVALS / "results").glob("run-*.jsonl"))
        rec = None
        if results:
            for line in reversed(results[-1].read_text().splitlines()):
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if r.get("harness") == v["harness"] and r.get("task") == v["task"]:
                    rec = r
                    break
        sandbox = EVALS / ".sandboxes" / f"{v['harness']}-{v['task']}-r1"
        extra = parse_traces(sandbox) if sandbox.exists() else {}
        row = {"variant": v["id"], "label": v["label"], **(rec or {}), **extra}
        rows.append(row)
        print(json.dumps({k: row.get(k) for k in (
            "variant", "outcome_ok", "wall_s", "rss_peak_kb", "tok_in", "tok_out",
            "tok_calls", "retried", "wrong_fields")}, default=str), flush=True)

    out = EVALS / "results" / "mcp-shapes-summary.json"
    out.write_text(json.dumps(rows, indent=2) + "\n")
    print(f"\nsummary → {out}")
    print(f"{'var':<4} {'pass':<5} {'wall':>7} {'RSS':>8} {'in':>8} {'out':>6} {'calls':>5} {'retry':<6} {'wrong':<6}  label")
    for row in rows:
        ok = "✓" if row.get("outcome_ok") else "✗"
        print(
            f"{row['variant']:<4} {ok:<5} {row.get('wall_s') or 0:7.1f} "
            f"{(row.get('rss_peak_kb') or 0) / 1024:7.1f}M "
            f"{row.get('tok_in') or 0:8} {row.get('tok_out') or 0:6} "
            f"{row.get('tok_calls') or 0:5} "
            f"{'yes' if row.get('retried') else 'no':<6} "
            f"{'yes' if row.get('wrong_fields') else 'no':<6}  {row['label']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
