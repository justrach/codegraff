#!/usr/bin/env python3
"""Live /btw prefix-cache check against a warmed Grok session.

    python3 scripts/btw-cache-showcase.py --bin ./zig-out/bin/graff --model grok-4.6
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

PING = "Reply with only the word ping. Do not call any tools."
BTW = "What single word did I ask you to reply with? Reply with only that word."


def resolve_bin(explicit: str) -> str:
    repo = Path(__file__).resolve().parent.parent
    if explicit:
        p = Path(explicit)
        if not p.is_absolute():
            p = (Path.cwd() / p).resolve()
        return str(p)
    cand = repo / "zig-out" / "bin" / "graff"
    return str(cand) if cand.is_file() else "graff"


def read_event(proc: subprocess.Popen, want: str, timeout_lines: int = 400) -> dict:
    assert proc.stdout
    for _ in range(timeout_lines):
        line = proc.stdout.readline()
        if not line:
            err = proc.stderr.read() if proc.stderr else ""
            raise SystemExit(f"graff closed before {want}\n{err[-800:]}")
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == want:
            return ev
    raise SystemExit(f"no {want} event in {timeout_lines} lines")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", default="")
    ap.add_argument("--model", default="grok-4.6")
    args = ap.parse_args()
    graff = resolve_bin(args.bin)
    env = os.environ.copy()
    env.update({"GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"})

    with tempfile.TemporaryDirectory(prefix="graff-btw-cache-") as tmp:
        proc = subprocess.Popen(
            [graff, "--json", "--yolo", "--no-telemetry", "--model", args.model],
            cwd=tmp,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert proc.stdin
        try:
            proc.stdin.write(json.dumps({"type": "user", "text": PING}) + "\n")
            proc.stdin.flush()
            turn = read_event(proc, "turn")
            proc.stdin.write(json.dumps({"type": "btw", "text": BTW}) + "\n")
            proc.stdin.flush()
            btw = read_event(proc, "btw")
            proc.stdin.close()
            proc.wait(timeout=30)
        finally:
            if proc.poll() is None:
                proc.kill()

    print(f"model {args.model}")
    print(f"turn  cache_read={turn.get('cache_read_tokens')}  uncached={turn.get('uncached_input_tokens')}  input={turn.get('input_tokens')}  text={turn.get('text')!r}")
    print(f"btw   cache_read={btw.get('cache_read_tokens')}  text={btw.get('text')!r}  persisted={btw.get('persisted')}")
    cached = int(btw.get("cache_read_tokens") or 0)
    prior = int(turn.get("input_tokens") or 0)
    print()
    if prior and cached >= int(prior * 0.8):
        print(f"hit: /btw reused {cached} tokens (≥80% of the prior {prior}-token turn)")
        return 0
    print(f"miss-or-weak: /btw reused {cached} of the prior {prior}-token turn")
    return 0


if __name__ == "__main__":
    sys.exit(main())
