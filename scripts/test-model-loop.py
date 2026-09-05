#!/usr/bin/env python3
"""Offline full-harness repetition regression; pass the built executable.

The loopback transport unit tests exercise all streaming wires. This script
additionally drives the real turn loop, final event, and subsequent request.
--eval-rows prints the two portable rows for the shared behavior suite.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("tier2", ROOT / "scripts/eval-tier2.py")
assert SPEC and SPEC.loader
TIER2 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TIER2)
PREFIX = "The useful answer is preserved.\n"
FILLER = "I will wait for your reply.\n"
MARKER = "stopped: model loop"


def cases():
    return [
        {"id": "model-loop-bounded-prose", "guards": "Repeated prose ends without user cancellation or retry", "prompt": "Give a brief plain text answer.",
         "args": ["--no-lean"], "script": [{"text": PREFIX + FILLER * 1000}],
         "assert": [{"final_text_contains": PREFIX.strip()}, {"final_text_contains": MARKER},
                    {"events_at_most": {"match": {"type": "turn"}, "count": 1}}]},
        {"id": "model-loop-fenced-data", "guards": "Legitimate fenced repetition remains intact", "prompt": "Return the requested literal data block.",
         "args": ["--no-lean"], "script": [{"text": "```text\n" + FILLER * 40 + "```"}],
         "assert": [{"final_text_contains": "```text\n" + FILLER * 40 + "```"}]},
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graff", nargs="?", default=str(ROOT / "zig-out/bin/graff"))
    parser.add_argument("--eval-rows", action="store_true")
    args = parser.parse_args()
    if args.eval_rows:
        for case in cases():
            print(json.dumps(case))
        return
    binary = str(pathlib.Path(args.graff).resolve())
    for case in cases():
        run = TIER2.execute(case, binary, 1234, None, None)
        failures = TIER2.evaluate(case, run)
        assert run.exit_code == 0, "harness did not exit successfully"
        assert not failures, failures
        assert len(run.requests) == 1, "loop stop must not retry or reopen the answer"
        if case["id"] == "model-loop-bounded-prose":
            assert len(run.final_text()) < 700, "repeated tail leaked into final text"
            emitted = "".join(str(e.get("text", "")) for e in run.events if e.get("type") == "text")
            assert len(emitted) < 1400, "repeated tail leaked into live delivery"
            assert not any(e.get("type") == "error" for e in run.events), "loop stop was misclassified as failure/cancel"
            assert "interrupted" not in run.final_text()
        print(case["id"] + ": ok")
    followup = cases()[0]
    followup["second_prompt"] = "Give another brief answer."
    followup["script"].append({"text": "The next answer is unaffected."})
    run = TIER2.execute(followup, binary, 1234, None, None)
    assert run.exit_code == 0 and len(run.requests) == 2
    assert run.final_text() == "The next answer is unaffected."
    history = json.dumps(run.requests[1])
    assert MARKER in history and PREFIX.strip() in history
    assert history.count(FILLER.strip()) < 30, "saved history retained the unbounded tail"
    print("model-loop-next-turn: ok")


if __name__ == "__main__":
    main()
