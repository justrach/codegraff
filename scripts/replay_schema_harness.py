#!/usr/bin/env python3
"""Replay a schema-harness trajectory into the codegraff.behavior.v1 envelope.

Issue #246 validation criterion: converting the published ft09 events.jsonl
and re-scoring the converted stream must reproduce its published RHAE of
100.0 using only the events themselves.

The conversion is intentionally mechanical. The codegraff envelope requires
kind, seq (contiguous from 1), ts, run_id, and schema on every line;
kind-specific fields stay flat and untouched, and consumers ignore top-level
fields they do not know. Nothing outside the event file is consulted, so the
converted stream stays recomputable on its own.

Usage:
    python3 scripts/replay_schema_harness.py events.jsonl converted.jsonl
    python3 scripts/score_run.py --profile replay \
        --baseline baseline_actions.csv --game ft09 converted.jsonl
"""

from __future__ import annotations

import argparse
import json
import secrets
import sys
from pathlib import Path

SCHEMA = "codegraff.behavior.v1"
ENVELOPE = ("kind", "seq", "ts", "run_id", "schema")


def convert(src: Path, dst: Path, run_id: str) -> dict:
    seq = 0
    kinds: dict[str, int] = {}
    with src.open(encoding="utf-8") as inp, dst.open("w", encoding="utf-8") as out:
        for line_no, line in enumerate(inp, start=1):
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if not isinstance(event, dict) or "kind" not in event:
                raise SystemExit(f"{src}:{line_no}: not an event object with a kind")
            seq += 1
            record = {
                "kind": event["kind"],
                "seq": seq,
                "ts": float(event.get("ts", 0.0)),
                "run_id": run_id,
                "schema": SCHEMA,
            }
            for key, value in event.items():
                if key not in ENVELOPE:
                    record[key] = value
            out.write(json.dumps(record, separators=(",", ":")) + "\n")
            kinds[event["kind"]] = kinds.get(event["kind"], 0) + 1
    return {"run_id": run_id, "events": seq, "kinds": dict(sorted(kinds.items()))}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="schema-harness events.jsonl")
    parser.add_argument("target", type=Path, help="output codegraff.behavior.v1 JSONL")
    parser.add_argument("--run-id", default=None, help="run identifier (default: random hex)")
    args = parser.parse_args()
    summary = convert(args.source, args.target, args.run_id or secrets.token_hex(8))
    json.dump(summary, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
