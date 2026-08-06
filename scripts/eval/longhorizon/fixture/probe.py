#!/usr/bin/env python3
"""Long-horizon memory probe.

Each `step N` emits a one-time TOKEN and then DESTROYS it on disk. After that
the token exists nowhere except the conversation, so recovering it later is a
pure memory question: no re-reading, no re-deriving. That property is the whole
point — a fact still readable from the filesystem tests nothing, because a
competent agent just reads it again and both arms score full marks.

Each step also emits filler kept deliberately under the #440 handle threshold,
so it accumulates in context rather than spilling to a handle, and drives real
compaction.
"""
import json, os, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent
STATE = ROOT / ".state.json"


def load():
    return json.loads(STATE.read_text())


def save(s):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(s))
    tmp.replace(STATE)


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "step":
        print("usage: probe.py step <N>")
        sys.exit(2)
    n = sys.argv[2]
    s = load()
    if n not in s["steps"]:
        print(f"no such step {n}; valid: {' '.join(sorted(s['steps'], key=int))}")
        sys.exit(2)

    entry = s["steps"][n]
    if entry["consumed"]:
        # The load-bearing behaviour: a consumed token is gone for good.
        print(f"step {n}: ALREADY CONSUMED — this token was emitted once and "
              f"erased. It cannot be recovered from disk. If you did not "
              f"record it, it is lost.")
        sys.exit(0)

    token = entry["token"]
    entry["consumed"] = True
    entry["token"] = None          # erased from disk, forever
    save(s)

    print(f"=== step {n} of {len(s['steps'])} ===")
    print(f"TOKEN-{n}: {token}")
    print(f"NOTE: that token has now been erased from disk. It will never be "
          f"printed again. You must carry it yourself to the end of this task.")
    nxt = entry.get("next")
    # The chain is what forces one model call per step. With a predictable
    # 1..N sequence the model simply batches every probe into a single turn,
    # context never accumulates and no compaction fires — measured, not
    # assumed: 14 predictable steps produced 9 api calls and 3 compactions.
    print(f"NEXT: run `python3 probe.py step {nxt}`" if nxt else
          "NEXT: none — this was the last step. Now report every token.")
    print()
    # Filler: bulk that fills context without tripping the handle threshold.
    for i in range(int(s["filler_lines"])):
        print(f"  [step {n}] scan {i:04d}  module=pkg/mod-{i:04d}  "
              f"status=OK  checksum={(hash((n, i)) & 0xffffff):06x}")


if __name__ == "__main__":
    main()
