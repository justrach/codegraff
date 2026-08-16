#!/usr/bin/env python3
"""Show how prompt cache looks: same process vs new process, same folder.

Not a unit test (needs a live provider).

    python3 scripts/cache-showcase.py
    python3 scripts/cache-showcase.py --model grok-4.6
    python3 scripts/cache-showcase.py --bin ./zig-out/bin/graff
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
PONG = "Reply with only the word pong. Do not call any tools."


def parse_turn_lines(stdout: str) -> list[dict]:
    turns = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "turn":
            turns.append(ev)
    return turns


def row_from_turn(label: str, turn: dict) -> tuple[str, dict]:
    return label, {
        "text": (turn.get("text") or "")[:40],
        "cache": int(turn.get("cache_read_tokens") or 0),
        "uncached": int(turn.get("uncached_input_tokens") or 0),
        "input": int(turn.get("input_tokens") or 0),
    }


def run_two_turns(graff: str, cwd: Path, model: str, env: dict) -> list[dict]:
    proc = subprocess.Popen(
        [graff, "--json", "--yolo", "--no-telemetry", "--model", model],
        cwd=cwd,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdin and proc.stdout
    turns: list[dict] = []
    buf = ""
    try:
        for prompt in (PING, PONG):
            proc.stdin.write(json.dumps({"type": "user", "text": prompt}) + "\n")
            proc.stdin.flush()
            while True:
                line = proc.stdout.readline()
                if not line:
                    raise SystemExit(f"graff closed stdout after {len(turns)} turn(s)")
                buf += line
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if ev.get("type") == "turn":
                    turns.append(ev)
                    break
        proc.stdin.close()
        proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            proc.kill()
    if len(turns) < 2:
        err = proc.stderr.read() if proc.stderr else ""
        raise SystemExit(f"expected 2 turns, got {len(turns)}\n{err[-800:]}")
    return turns


def run_one_turn(graff: str, cwd: Path, model: str, prompt: str, env: dict) -> dict:
    proc = subprocess.run(
        [graff, "--json", "--yolo", "--no-telemetry", "--model", model],
        input=json.dumps({"type": "user", "text": prompt}) + "\n",
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    turns = parse_turn_lines(proc.stdout)
    if not turns:
        tail = "\n".join((proc.stderr or "").strip().splitlines()[-8:])
        raise SystemExit(f"graff exited {proc.returncode} in {cwd}:\n{tail}")
    return turns[-1]


def resolve_bin(explicit: str) -> str:
    repo = Path(__file__).resolve().parent.parent
    if explicit:
        p = Path(explicit)
        if not p.is_absolute():
            p = (Path.cwd() / p).resolve()
        return str(p)
    cand = repo / "zig-out" / "bin" / "graff"
    return str(cand) if cand.is_file() else "graff"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", default="")
    ap.add_argument("--model", default="grok-4.6")
    args = ap.parse_args()
    graff = resolve_bin(args.bin)

    env = os.environ.copy()
    env.update({"GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"})

    print(f"model {args.model}")
    print("what this is:")
    print("  same process  = you stay in the TUI (⚡ cached on the status line)")
    print("  new process   = quit, come back, first request of a new session")
    print("  other folder  = different project key, should stay colder")
    print()

    with tempfile.TemporaryDirectory(prefix="graff-cache-show-") as tmp:
        same = Path(tmp) / "same-repo"
        other = Path(tmp) / "other-repo"
        same.mkdir()
        other.mkdir()

        print("1/3 two turns in one process…", flush=True)
        t1, t2 = run_two_turns(graff, same, args.model, env)
        print("2/3 new process, same folder…", flush=True)
        t3 = run_one_turn(graff, same, args.model, PONG, env)
        print("3/3 new process, other folder…", flush=True)
        t4 = run_one_turn(graff, other, args.model, PONG, env)

    rows = [
        row_from_turn("same process · turn 1 (write prefix)", t1),
        row_from_turn("same process · turn 2 (append only)", t2),
        row_from_turn("new process  · same folder", t3),
        row_from_turn("new process  · other folder", t4),
    ]

    print()
    print(f"{'step':<44} {'cache':>8} {'uncached':>10} {'input':>8}  reply")
    print("-" * 84)
    for label, r in rows:
        print(f"{label:<44} {r['cache']:>8} {r['uncached']:>10} {r['input']:>8}  {r['text']!r}")
    print()
    print("cache = tokens the provider reused. uncached = tokens it recomputed.")
    print("turn events are session-cumulative; turn 2's cache should jump.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
