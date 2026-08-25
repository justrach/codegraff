#!/usr/bin/env python3
"""Compare native structured tool calls vs --rlm (spec-ptc) on the same prompt.

Runs graff twice against a three-file fixture and prints tool_call shape +
timing. Default binary: zig-out/bin/graff, then $PATH graff.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


PROMPT = """Read the FIRST line of each of these three files and report them as
a three-line list (file: line). Do not use bash. Files:
  a.txt
  b.txt
  c.txt
"""

RLM_HINT = """
You MUST use the rlm tool once. Write a short script:
  a = read_file("a.txt")
  b = read_file("b.txt")
  c = read_file("c.txt")
  print(a)
  print(b)
  print(c)
Do not call read_file as a top-level tool.
"""


def graff_bin() -> str:
    here = Path(__file__).resolve().parents[1] / "zig-out" / "bin" / "graff"
    if here.exists():
        return str(here)
    return "graff"


def run(bin: str, extra: list[str], prompt: str, cwd: str) -> dict:
    # --json is the NDJSON protocol (stdin request, stdout events). -p prints
    # the human answer on stdout and hides tool_call events.
    cmd = [bin, "--json", "--yolo", "--no-lean", "--model", "grok-4.6", *extra]
    req = json.dumps({"type": "user", "text": prompt}) + "\n"
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=cwd, text=True, input=req, capture_output=True)
    ms = int((time.perf_counter() - t0) * 1000)
    events = []
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    tools = [e for e in events if e.get("type") == "tool_call"]
    finished = [e for e in events if e.get("type") == "tool_call_finished"]
    turns = [e for e in events if e.get("type") == "turn"]
    answer = turns[-1].get("text", "") if turns else ""
    return {
        "ok": proc.returncode == 0,
        "ms": ms,
        "stderr": (proc.stderr or "")[-800:],
        "event_types": [e.get("type") for e in events],
        "tools": [{"name": t.get("name"), "input": t.get("input")} for t in tools],
        "finished_ms": [e.get("ms") for e in finished],
        "names": [t.get("name") for t in tools],
        "answer": answer[-800:],
        "usage": {k: turns[-1].get(k) for k in ("api_calls", "input_tokens", "output_tokens", "cache_read_tokens")} if turns else {},
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--graff", default=graff_bin())
    ap.add_argument("--skip-live", action="store_true", help="print the plan only")
    args = ap.parse_args()
    if args.skip_live:
        print("native: structured read_file x3 (or however the model fans out)")
        print("rlm:    one rlm script; Zig speculator launches the three reads together")
        return 0

    with tempfile.TemporaryDirectory() as td:
        Path(td, "a.txt").write_text("alpha-first\nrest-a\n")
        Path(td, "b.txt").write_text("bravo-first\nrest-b\n")
        Path(td, "c.txt").write_text("charlie-first\nrest-c\n")
        print(f"graff={args.graff}", flush=True)
        print("=== native (structured tools) ===", flush=True)
        native = run(args.graff, [], PROMPT, td)
        print(json.dumps({k: native[k] for k in ("ok", "ms", "names", "finished_ms", "usage", "event_types")}, indent=2))
        print("=== rlm (--rlm, speculated reads) ===", flush=True)
        rlm = run(args.graff, ["--rlm"], PROMPT + RLM_HINT, td)
        print(json.dumps({k: rlm[k] for k in ("ok", "ms", "names", "finished_ms", "usage", "event_types")}, indent=2))
        print("=== answers ===")
        print("native:\n", native.get("answer") or native.get("stderr"))
        print("rlm:\n", rlm.get("answer") or rlm.get("stderr"))
        if native.get("stderr") and not native["ok"]:
            print("native stderr:\n", native["stderr"], file=sys.stderr)
        if rlm.get("stderr") and not rlm["ok"]:
            print("rlm stderr:\n", rlm["stderr"], file=sys.stderr)
    return 0 if native["ok"] and rlm["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
