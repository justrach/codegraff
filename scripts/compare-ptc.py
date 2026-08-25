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
    cmd = [bin, "-p", "--json", "--yolo", "--model", "grok-4.6", *extra, prompt]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
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
    text_bits = [e.get("text", "") for e in events if e.get("type") in ("text", "assistant", "turn") and e.get("text")]
    return {
        "ok": proc.returncode == 0,
        "ms": ms,
        "stderr": (proc.stderr or "")[-800:],
        "tools": [{"name": t.get("name"), "input": t.get("input")} for t in tools],
        "finished_ms": [e.get("ms") for e in finished],
        "names": [t.get("name") for t in tools],
        "answer": "\n".join(text_bits)[-500:],
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
        native = run(args.graff, ["--no-lean"], PROMPT, td)
        print(json.dumps({k: native[k] for k in ("ok", "ms", "names", "finished_ms")}, indent=2))
        print("=== rlm (--rlm, speculated reads) ===", flush=True)
        rlm = run(args.graff, ["--no-lean", "--rlm"], PROMPT + RLM_HINT, td)
        print(json.dumps({k: rlm[k] for k in ("ok", "ms", "names", "finished_ms")}, indent=2))
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
