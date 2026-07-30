#!/usr/bin/env python3
"""Tier 2 of the internal eval set: model-backed harness behavior.

Tier 1 (scripts/eval-tier1.sh) proves the code compiles, the tests run, and the
generated artifacts match. It cannot tell you whether a real run *behaves*: that
a goal produces a checklist and can finish it, that an empty todo_write leaves
the list alone, that compaction does not lose completed work. Those need a model
in the loop, which is why this tier is not in the pre-push hook.

The cases are data - evals/harness_behavior.jsonl - and each one carries the
regression it guards. A case scripts the model's replies, so the default run is
offline and free: scripts/eval/mock_model.py replays the script on the fixed
lmstudio port and records what the harness sent back. Point --provider/--model
at a real provider to run the same cases against one.

  python3 scripts/eval-tier2.py                       every case, scripted model
  python3 scripts/eval-tier2.py --only todo-empty-write-noop
  python3 scripts/eval-tier2.py --list
  python3 scripts/eval-tier2.py --dump goal-checklist-completes

Assertions a case can make:

  {"event": {...}}                        some emitted event matches this subset
  {"no_event": {...}}                     none does
  {"events_at_least": {"match": {...}, "count": N}}
  {"events_at_most":  {"match": {...}, "count": N}}
  {"request_contains": {"index": -1, "text": "..."}}   what the harness sent
  {"request_lacks":    {"index": -1, "text": "..."}}
  {"final_text_contains": "..."}
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from typing import Any

REPO = pathlib.Path(__file__).resolve().parents[1]
CASES = REPO / "evals" / "harness_behavior.jsonl"
sys.path.insert(0, str(REPO / "scripts" / "eval"))
from mock_model import ScriptedModel  # noqa: E402


def load_cases() -> list[dict[str, Any]]:
    cases = []
    for number, line in enumerate(CASES.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        try:
            cases.append(json.loads(line))
        except ValueError as exc:
            sys.exit(f"eval-tier2: {CASES}:{number} is not valid JSON: {exc}")
    return cases


def subset_matches(event: dict[str, Any], wanted: dict[str, Any]) -> bool:
    for key, value in wanted.items():
        if key not in event:
            return False
        if isinstance(value, dict):
            if not isinstance(event[key], dict) or not subset_matches(event[key], value):
                return False
        elif event[key] != value:
            return False
    return True


class Run:
    """One harness run: the events it emitted and the requests it sent."""

    def __init__(self, events: list[dict[str, Any]], requests: list[dict[str, Any]],
                 stderr: str, exit_code: int | None) -> None:
        self.events = events
        self.requests = requests
        self.stderr = stderr
        self.exit_code = exit_code

    def final_text(self) -> str:
        for event in reversed(self.events):
            if event.get("type") == "turn":
                return str(event.get("text", ""))
        return ""

    def request_text(self, index: int) -> str | None:
        if not self.requests:
            return None
        try:
            return json.dumps(self.requests[index])
        except IndexError:
            return None


def execute(case: dict[str, Any], graff: str, port: int,
            provider: str | None, model: str | None) -> Run:
    scripted = ScriptedModel(case.get("script", []))
    bound = 0 if provider else scripted.start(port)
    try:
        with tempfile.TemporaryDirectory(prefix="graff-tier2-") as workspace:
            env = {
                key: value for key, value in os.environ.items()
                if not key.endswith("_API_KEY")
            }
            env.update({
                "HOME": workspace,
                "LMSTUDIO_API_KEY": "local",
                "GRAFF_NO_TELEMETRY": "1",
                "GRAFF_FLEET": "off",
                "GRAFF_NO_SMOLIFY": "1",
                "NO_COLOR": "1",
            })
            # Per-case environment. A case that needs the harness to reach a
            # state it will not reach on its own - a tiny context window so a
            # SUBAGENT compacts, say - sets it here rather than in the shared
            # block, so one case cannot quietly change the others.
            env.update({k: str(v) for k, v in case.get("env", {}).items()})
            argv = [graff, "--json", "--yolo", "--model", model or "lmstudio"]
            if provider:
                argv += ["--subagent-provider", provider]
            argv += list(case.get("args", []))

            stdin_lines = [json.dumps({"type": "user", "text": case["prompt"]})]
            for control in case.get("controls_after_turn", []):
                stdin_lines.append(json.dumps(control))
            if case.get("second_prompt"):
                stdin_lines.append(json.dumps({"type": "user", "text": case["second_prompt"]}))

            try:
                done = subprocess.run(
                    argv, cwd=workspace, env=env, text=True, capture_output=True,
                    input="\n".join(stdin_lines) + "\n",
                    timeout=case.get("timeout_s", 60),
                )
                stdout, stderr, code = done.stdout, done.stderr, done.returncode
            except subprocess.TimeoutExpired as exc:
                stdout = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout or b"").decode("utf-8", "ignore")
                stderr = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode("utf-8", "ignore")
                code = None

            events = []
            for line in stdout.splitlines():
                line = line.strip()
                if line.startswith("{"):
                    try:
                        events.append(json.loads(line))
                    except ValueError:
                        pass
            return Run(events, list(scripted.requests), stderr, code)
    finally:
        if bound:
            scripted.stop()
            # The port is fixed, so let the socket clear before the next case.
            time.sleep(0.05)


def evaluate(case: dict[str, Any], run: Run) -> list[str]:
    failures = []
    for claim in case.get("assert", []):
        (kind, spec), = claim.items()
        if kind == "event":
            if not any(subset_matches(e, spec) for e in run.events):
                failures.append(f"no event matched {json.dumps(spec)}")
        elif kind == "no_event":
            if any(subset_matches(e, spec) for e in run.events):
                failures.append(f"an event matched {json.dumps(spec)} and none should have")
        elif kind in ("events_at_least", "events_at_most"):
            seen = sum(1 for e in run.events if subset_matches(e, spec["match"]))
            want = spec["count"]
            if kind == "events_at_least" and seen < want:
                failures.append(
                    f"{seen} event(s) matched {json.dumps(spec['match'])}, wanted at least {want}")
            if kind == "events_at_most" and seen > want:
                failures.append(
                    f"{seen} event(s) matched {json.dumps(spec['match'])}, wanted at most {want}")
        elif kind in ("request_contains", "request_lacks"):
            body = run.request_text(spec.get("index", -1))
            if body is None:
                failures.append(f"the harness sent no request at index {spec.get('index', -1)}")
                continue
            present = spec["text"] in body
            if kind == "request_contains" and not present:
                failures.append(
                    f"request[{spec.get('index', -1)}] never mentioned {spec['text']!r}")
            if kind == "request_lacks" and present:
                failures.append(
                    f"request[{spec.get('index', -1)}] mentioned {spec['text']!r} and should not have")
        elif kind == "final_text_contains":
            if spec not in run.final_text():
                failures.append(f"the final answer was {run.final_text()!r}, wanted {spec!r}")
        else:
            failures.append(f"unknown assertion {kind!r}")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--graff", default=str(REPO / "zig-out" / "bin" / "graff"))
    parser.add_argument("--only", action="append", default=[], help="case id (repeatable)")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--dump", help="run one case and print its events and requests")
    parser.add_argument("--port", type=int, default=1234, help="scripted-model port")
    parser.add_argument("--provider", help="run against a real provider instead of the script")
    parser.add_argument("--model", help="model name for --provider")
    args = parser.parse_args()

    cases = load_cases()
    if args.list:
        for case in cases:
            print(f"{case['id']}\n    {case['why']}")
        return

    wanted = set(args.only) | ({args.dump} if args.dump else set())
    if wanted:
        known = {case["id"] for case in cases}
        missing = wanted - known
        if missing:
            sys.exit(f"eval-tier2: no case named {', '.join(sorted(missing))} (try --list)")
        cases = [case for case in cases if case["id"] in wanted]

    if not pathlib.Path(args.graff).exists():
        sys.exit(f"eval-tier2: {args.graff} does not exist - run `zig build` first")

    if args.provider:
        print(f"tier 2: {len(cases)} case(s) against {args.provider}"
              f"/{args.model or 'default'} - this spends real calls\n")
    else:
        print(f"tier 2: {len(cases)} case(s) against the scripted model"
              f" on 127.0.0.1:{args.port} - offline, no spend\n")

    failed = []
    for case in cases:
        run = execute(case, args.graff, args.port, args.provider, args.model)
        if args.dump:
            print(json.dumps({"events": run.events, "requests": run.requests,
                              "exit_code": run.exit_code, "stderr": run.stderr[-2000:]},
                             indent=2))
            return
        problems = evaluate(case, run)
        # A harness that crashed, hung, or died instantly must FAIL the case on
        # its own, not merely annotate someone else's failure. Without this a
        # case whose assertions are all upper bounds passes against a binary
        # that never ran at all.
        if run.exit_code not in (0, None):
            problems.append(f"graff exited {run.exit_code}")
        elif run.exit_code is None:
            problems.append("graff did not exit (timed out)")
        if problems:
            failed.append(case["id"])
            print(f"  FAIL  {case['id']}")
            print(f"        guards: {case['why']}")
            for problem in problems:
                print(f"        - {problem}")
            if run.exit_code not in (0, None):
                print(f"        graff exited {run.exit_code}; stderr tail:")
                print("        " + run.stderr.strip().splitlines()[-1] if run.stderr.strip() else "")
        else:
            print(f"  pass  {case['id']}")

    print()
    if failed:
        print(f"tier 2 red - {len(failed)} of {len(cases)} case(s) failed: {', '.join(failed)}")
        print("rerun one with: python3 scripts/eval-tier2.py --only <id>")
        print("see everything it did: python3 scripts/eval-tier2.py --dump <id>")
        sys.exit(1)
    print(f"tier 2 green - {len(cases)} case(s)")


if __name__ == "__main__":
    main()
