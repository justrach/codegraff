#!/usr/bin/env python3
"""Run graff --json for one prompt at a chosen effort, for run.py harnesses.

Prints the final answer on stdout and the cumulative usage footer on stderr in
the `[usage] …` shape measurement.graff_usage reads. GRAFF_BIN picks the binary.
"""
import argparse
import json
import os
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--effort", default="default")
ap.add_argument("--model", required=True)
ap.add_argument("prompt")
args = ap.parse_args()

lines = [] if args.effort == "default" else [json.dumps({"type": "set_effort", "level": args.effort})]
lines.append(json.dumps({"type": "user", "text": args.prompt}))
proc = subprocess.run([os.environ.get("GRAFF_BIN", "graff"), "--json", "--model", args.model, "--yolo"],
                      input="\n".join(lines) + "\n", capture_output=True, text=True)
turn, errors = None, []
for line in proc.stdout.splitlines():
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") == "turn":
        turn = ev
    elif ev.get("type") == "error":
        errors.append(ev.get("message", ""))
if turn is None:
    sys.stderr.write(proc.stderr[-2000:] + "\n" + "\n".join(errors) + "\n")
    sys.exit(proc.returncode or 1)
print(turn.get("text", ""))
cost = turn.get("cost_usd")
sys.stderr.write(f"[usage] {turn.get('api_calls', 0)} api call(s) · {turn.get('input_tokens', 0)} in "
                 f"({turn.get('cache_read_tokens', 0)} cached) + {turn.get('output_tokens', 0)} out tokens"
                 + (f" · ${cost:.6f}" if cost is not None else "") + "\n")
