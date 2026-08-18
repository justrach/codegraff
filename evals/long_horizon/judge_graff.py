#!/usr/bin/env python3
"""Adapt Graff into the optional JSON-in/JSON-out quality judge interface."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "number", "minimum": 0, "maximum": 1},
        "reason": {"type": "string"},
    },
    "required": ["score", "reason"],
    "additionalProperties": False,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model", default="gpt-5.6-luna")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid judge payload: {exc}")
    prompt = (
        "You are a secondary code-quality judge. The external verifier has already "
        "established correctness. Assess only maintainability, clarity, and scope "
        "discipline from the bounded diff. Do not reward extra features. Follow the "
        "requested JSON schema.\n\n" + json.dumps(payload, sort_keys=True)
    )
    run = subprocess.run(
        [
            str(args.binary.resolve()),
            "-p", prompt,
            "--model", args.model,
            "--output-schema", json.dumps(SCHEMA, separators=(",", ":")),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=args.timeout,
    )
    if run.returncode != 0:
        raise SystemExit(run.stderr[-1000:] or f"judge exited {run.returncode}")
    try:
        result = json.loads(run.stdout)
        score = float(result["score"])
        reason = str(result["reason"])
        if not 0 <= score <= 1:
            raise ValueError("score outside 0..1")
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
        raise SystemExit(f"invalid model judge output: {exc}")
    print(json.dumps({"score": score, "reason": reason}, separators=(",", ":")))


if __name__ == "__main__":
    main()
