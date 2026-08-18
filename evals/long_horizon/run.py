#!/usr/bin/env python3
"""Run a harness in a generated long-horizon environment and grade it."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from environment import ENVIRONMENT_ID, TASK_PROMPT, materialize
from grader import grade, solution_diff
from reference import apply_reference

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
HARNESS_CONFIG = REPO / "graff-evals" / "harnesses.json"
RESULTS = ROOT / "results"
USAGE_RE = re.compile(
    r"\[usage\] (\d+) api call\(s\) · (\d+) in \((\d+) cached\) \+ (\d+) out tokens"
)


def load_harness(name: str) -> dict[str, object]:
    harnesses = json.loads(HARNESS_CONFIG.read_text(encoding="utf-8"))
    if name not in harnesses:
        raise SystemExit(f"unknown harness {name!r}; choose from {', '.join(harnesses)}")
    return harnesses[name]


def initialize_workspace(workspace: Path, seed: int) -> None:
    materialize(workspace, seed)
    subprocess.run(["git", "init", "-q"], cwd=workspace, check=True)
    subprocess.run(["git", "add", "-A"], cwd=workspace, check=True)
    subprocess.run(
        ["git", "-c", "user.name=Eval Fixture", "-c", "user.email=eval@invalid",
         "commit", "-qm", "synthetic baseline"],
        cwd=workspace,
        check=True,
    )


def harness_command(harness: dict[str, object], model: str) -> list[str]:
    values = {"prompt": TASK_PROMPT, "model": model, "repo": str(REPO)}
    return [str(part).format(**values) for part in harness["cmd"]]


def run_process(
    command: list[str], workspace: Path, env: dict[str, str], timeout: int
) -> dict[str, object]:
    started = time.monotonic()
    first_output = None
    stdout_parts: list[str] = []
    stderr_parts: list[str] = []
    process = subprocess.Popen(
        command,
        cwd=workspace,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None and process.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, stdout_parts)
    selector.register(process.stderr, selectors.EVENT_READ, stderr_parts)
    streams = 2
    while streams and time.monotonic() - started < timeout:
        for key, _ in selector.select(timeout=0.5):
            line = key.fileobj.readline()
            if not line:
                selector.unregister(key.fileobj)
                streams -= 1
                continue
            if first_output is None:
                first_output = time.monotonic() - started
            key.data.append(line)
    timed_out = process.poll() is None
    if timed_out:
        process.kill()
    process.wait(timeout=10)
    return {
        "exit": process.returncode,
        "timed_out": timed_out,
        "wall_s": round(time.monotonic() - started, 3),
        "first_output_s": round(first_output, 3) if first_output is not None else None,
        "stdout": "".join(stdout_parts),
        "stderr": "".join(stderr_parts),
    }


def usage_from(stderr: str) -> dict[str, int]:
    match = USAGE_RE.search(stderr)
    if not match:
        return {}
    calls, input_tokens, cached_tokens, output_tokens = map(int, match.groups())
    return {
        "model_calls": calls,
        "input_tokens": input_tokens,
        "cached_tokens": cached_tokens,
        "output_tokens": output_tokens,
    }


def efficiency_score(wall_s: float, model_calls: int | None) -> float:
    calls = 0.5 if model_calls is None else 1 / (1 + max(0, model_calls - 12) / 12)
    latency = 1 / (1 + max(0.0, wall_s - 300) / 600)
    return round((calls + latency) / 2, 6)


def model_judge(
    command: str | None,
    workspace: Path,
    seed: int,
    deterministic_report: dict[str, object],
) -> tuple[float, dict[str, object]]:
    if not command:
        return 0.5, {"used": False, "score": 0.5, "reason": "neutral default"}
    payload = {
        "rubric": (
            "Judge only maintainability, clarity, and scope discipline. Correctness has "
            "already been verified. Return JSON: {\"score\": 0..1, \"reason\": \"...\"}."
        ),
        "task": TASK_PROMPT,
        "deterministic_report": deterministic_report,
        "solution_diff": solution_diff(workspace, seed),
    }
    try:
        run = subprocess.run(
            shlex.split(command),
            input=json.dumps(payload),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )
        value = json.loads(run.stdout)
        score = float(value["score"])
        if run.returncode != 0 or not 0 <= score <= 1:
            raise ValueError("invalid judge result")
        return score, {"used": True, "score": score, "reason": str(value.get("reason", ""))[:500]}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, json.JSONDecodeError) as exc:
        return 0.0, {"used": True, "score": 0.0, "error": str(exc), "fail_closed": True}


def final_reward(
    deterministic: dict[str, object],
    wall_s: float,
    model_calls: int | None,
    judge_score: float,
) -> tuple[float, float]:
    if not deterministic["deterministic_pass"]:
        return float(deterministic["score"]), 0.0
    efficiency = efficiency_score(wall_s, model_calls)
    return round(0.9 + 0.05 * efficiency + 0.05 * judge_score, 6), efficiency


def one_run(args: argparse.Namespace, rep: int) -> dict[str, object]:
    base = Path(tempfile.mkdtemp(prefix=f"graff-{ENVIRONMENT_ID}-"))
    workspace = base / "workspace"
    initialize_workspace(workspace, args.seed + rep - 1)
    harness = load_harness(args.harness)
    command = harness_command(harness, args.model)
    env = dict(os.environ, **{str(k): str(v) for k, v in harness.get("env", {}).items()})
    process = run_process(command, workspace, env, args.timeout)
    deterministic = grade(workspace, args.seed + rep - 1)
    usage = usage_from(str(process["stderr"]))
    judge_score, judge = model_judge(
        args.judge_command if deterministic["deterministic_pass"] else None,
        workspace,
        args.seed + rep - 1,
        deterministic,
    )
    reward, efficiency = final_reward(
        deterministic,
        float(process["wall_s"]),
        usage.get("model_calls"),
        judge_score,
    )
    record = {
        "environment": ENVIRONMENT_ID,
        "seed": args.seed + rep - 1,
        "rep": rep,
        "harness": args.harness,
        "model": args.model,
        "reward": reward,
        "efficiency": efficiency,
        "grader": deterministic,
        "judge": judge,
        "process": {key: value for key, value in process.items() if key not in {"stdout", "stderr"}},
        "usage": usage,
        "answer_head": str(process["stdout"])[:300],
    }
    if args.keep:
        kept = ROOT / ".runs" / f"{int(time.time())}-{rep}"
        kept.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(workspace), kept)
        record["workspace"] = str(kept)
        shutil.rmtree(base, ignore_errors=True)
    else:
        shutil.rmtree(base, ignore_errors=True)
    return record


def self_test(seed: int) -> None:
    with tempfile.TemporaryDirectory(prefix="graff-long-horizon-selftest-") as raw:
        workspace = Path(raw)
        materialize(workspace, seed)
        baseline = grade(workspace, seed)
        if baseline["deterministic_pass"]:
            raise SystemExit("self-test failed: unfinished baseline passed")
        apply_reference(workspace)
        solved = grade(workspace, seed)
        if not solved["deterministic_pass"]:
            print(json.dumps(solved, indent=2))
            raise SystemExit("self-test failed: reference solution did not pass")
        (workspace / "TASK.md").write_text("tampered\n", encoding="utf-8")
        tampered = grade(workspace, seed)
        if tampered["score"] != 0.0:
            raise SystemExit("self-test failed: fixture tampering was not fatal")
    print(f"self-test ok: baseline rejected, reference accepted, tampering rejected (seed {seed})")


def showcase(seed: int) -> None:
    """Print one generated task and its externally verified reward path."""
    with tempfile.TemporaryDirectory(prefix="graff-long-horizon-showcase-") as raw:
        workspace = Path(raw)
        materialize(workspace, seed)
        seed_data = json.loads((workspace / ".eval-seed.json").read_text(encoding="utf-8"))
        paths = sorted(
            str(path.relative_to(workspace))
            for path in workspace.rglob("*")
            if path.is_file()
        )
        baseline = grade(workspace, seed)

        print(f"{ENVIRONMENT_ID} / seed {seed}")
        balances = ", ".join(
            f"{account}={balance}"
            for account, balance in seed_data["balances"].items()
        )
        print(f"Fixture accounts: {balances}")
        print("\nGenerated repository:")
        for relative in paths:
            print(f"  {relative}")
        print("\nAgent task (TASK.md):")
        for line in (workspace / "TASK.md").read_text(encoding="utf-8").splitlines():
            print(f"  {line}")
        print(
            f"\nUnfinished baseline: {baseline['passed']}/{baseline['total']} checks, "
            f"score={baseline['score']:.3f} (expected failure)"
        )

        apply_reference(workspace)
        solved = grade(workspace, seed)
        if not solved["deterministic_pass"]:
            raise SystemExit("showcase failed: bundled reference solution did not pass")
        print("\nExternal verifier after the bundled reference patch:")
        for result in solved["checks"]:
            print(f"  [PASS] {result['name']}")
        print(
            f"Reference solution: {solved['passed']}/{solved['total']} checks; "
            "deterministic reward floor=0.900"
        )
        print("Model quality may add at most 0.050, only after this complete pass.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", default="graff-dev")
    parser.add_argument("--model", default="gpt-5.6-luna")
    parser.add_argument("--seed", type=int, default=469)
    parser.add_argument("--reps", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--judge-command", help="external JSON-in/JSON-out maintainability judge")
    parser.add_argument("--keep", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--showcase", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(args.seed)
        return
    if args.showcase:
        showcase(args.seed)
        return

    RESULTS.mkdir(parents=True, exist_ok=True)
    output = RESULTS / f"run-{time.strftime('%Y%m%d-%H%M%S')}.jsonl"
    records = []
    with output.open("w", encoding="utf-8") as stream:
        for rep in range(1, args.reps + 1):
            record = one_run(args, rep)
            records.append(record)
            stream.write(json.dumps(record, sort_keys=True) + "\n")
            stream.flush()
            print(
                f"rep {rep}: reward={record['reward']:.3f} "
                f"checks={record['grader']['passed']}/{record['grader']['total']} "
                f"wall={record['process']['wall_s']}s"
            )
    passed = sum(record["grader"]["deterministic_pass"] for record in records)
    mean = sum(record["reward"] for record in records) / len(records)
    print(f"summary: {passed}/{len(records)} deterministic pass; mean reward={mean:.3f}")
    print(f"results: {output}")


if __name__ == "__main__":
    main()
