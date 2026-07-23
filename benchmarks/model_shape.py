#!/usr/bin/env python3
"""Correctness-first benchmark for Sol-root / configurable-worker shapes.

The benchmark creates fresh synthetic repositories, asks graff to use exactly
two parallel direct subagents, grades the result with visible and held-back
tests, and reads run-local traces for latency/tool/model evidence. No source
from the repository containing this script is sent to a model.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Any

from model_shape_frontend_tasks import TASKS as FRONTEND_TASKS
from model_shape_metrics import quality_diversity
from model_shape_tasks import TASKS as CORE_TASKS, Task


ROOT_PROVIDER = "codex"
ROOT_MODEL = "gpt-5.6-sol"
WORKER_MODEL = "gpt-5.6-terra"
MINIMUM_PAIRS_FOR_PROMOTION = 20
ALL_TASKS = CORE_TASKS + FRONTEND_TASKS


@dataclass(frozen=True)
class Arm:
    name: str
    worker_provider: str
    worker_model: str
    allow_cross_provider: bool


def arm_for(spec: str) -> Arm:
    try:
        provider, model = spec.split(":", 1)
    except ValueError as exc:
        raise ValueError("worker shape must be provider:model") from exc
    if not provider or not model:
        raise ValueError("worker shape must be provider:model")
    if provider == ROOT_PROVIDER and model == ROOT_MODEL:
        name = "all-sol"
    elif provider == ROOT_PROVIDER:
        name = "sol-" + model.removeprefix("gpt-5.6-")
    else:
        safe_model = re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")
        name = f"sol-{provider}-{safe_model}"
    return Arm(name, provider, model, provider != ROOT_PROVIDER)


COMMON_REQUEST = """
This is a controlled benchmark in a disposable synthetic repository.
Use exactly two direct `subagent` tool calls, issued together in one response
so they run in parallel. Ask one worker to analyze the implementation and edge
cases, and the other to inspect the tests/specification and propose a test
matrix. The workers must only inspect and report; they must not edit files.
After both reports return, integrate their findings yourself, edit only the
implementation file, and run the visible unittest suite. Do not edit tests,
do not use workflow/learn tools, and do not merely describe a solution.
""".strip()

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_jsonl_files(paths: list[Path]) -> list[dict[str, Any]]:
    rows = []
    for path in paths:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                rows.append(value)
    return rows


def count_unittest_results(output: str, expected: int, returncode: int) -> int:
    match = re.search(r"Ran (\d+) tests?", output)
    total = int(match.group(1)) if match else expected
    if returncode == 0:
        return min(total, expected)
    failures = sum(
        int(value)
        for value in re.findall(r"(?:failures|errors)=(\d+)", output)
    )
    return max(0, min(expected, total - max(1, failures)))


def run_checks(task: Task, root: Path, test_hash: str) -> dict[str, Any]:
    visible = subprocess.run(
        [sys.executable, "-m", "unittest", "-q"],
        cwd=root,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    visible_output = visible.stdout + visible.stderr
    visible_passed = count_unittest_results(
        visible_output, task.visible_count, visible.returncode
    )
    hidden = subprocess.run(
        [sys.executable, "-c", task.hidden_grader],
        cwd=root,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    hidden_results: dict[str, Any] = {}
    try:
        hidden_results = json.loads(hidden.stdout.splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        pass
    hidden_passed = sum(value is True for value in hidden_results.values())
    tests_unchanged = sha256(root / "test_public.py") == test_hash
    passed = visible_passed + hidden_passed if tests_unchanged else 0
    total = task.visible_count + task.hidden_count
    return {
        "passed": passed,
        "total": total,
        "fully_correct": passed == total,
        "visible_passed": visible_passed,
        "hidden_passed": hidden_passed,
        "hidden_results": hidden_results,
        "tests_unchanged": tests_unchanged,
        "visible_output": visible_output[-3000:],
        "hidden_stderr": hidden.stderr[-1000:],
    }


def initialize_workspace(root: Path, task: Task) -> str:
    root.mkdir(parents=True)
    (root / task.source_name).write_text(task.source, encoding="utf-8")
    test_path = root / "test_public.py"
    test_path.write_text(task.visible_tests, encoding="utf-8")
    harness = root / ".harness"
    harness.mkdir()
    (harness / "settings.json").write_text(
        json.dumps({"ai_title": False, "skills": {"codedbpro": False}}),
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "add", task.source_name, "test_public.py"], cwd=root, check=True)
    subprocess.run(
        [
            "git", "-c", "user.name=shape-bench",
            "-c", "user.email=shape-bench@invalid",
            "commit", "--no-gpg-sign", "-qm", "fixture",
        ],
        cwd=root,
        check=True,
    )
    return sha256(test_path)


def trace_metrics(root: Path, arm: Arm) -> dict[str, Any]:
    trace_rows = read_jsonl_files(sorted((root / ".graff/traces").glob("*.jsonl")))
    traj_rows = read_jsonl_files(
        sorted((root / ".graff/trajectories").glob("*.jsonl"))
    )
    api = [row for row in trace_rows if row.get("ev") == "api"]
    tools = [row for row in trace_rows if row.get("ev") == "tool"]
    retries = [row for row in trace_rows if row.get("ev") == "retry"]
    children = [row for row in traj_rows if row.get("kind") == "subagent"]
    root_api = [row for row in api if row.get("agent") == "main"]
    worker_api = [row for row in api if row.get("agent") != "main"]
    expected_children = all(row.get("model") == arm.worker_model for row in children)
    expected_child_providers = all(
        row.get("provider") == arm.worker_provider for row in children
    )
    expected_root = all(row.get("model") == ROOT_MODEL for row in root_api)
    expected_worker_api = all(
        row.get("model") == arm.worker_model for row in worker_api
    )
    return {
        "api_calls": len(api),
        "root_api_calls": len(root_api),
        "worker_api_calls": len(worker_api),
        "api_ms_sum": sum(max(0, row.get("ms", 0)) for row in api),
        "root_api_ms_sum": sum(max(0, row.get("ms", 0)) for row in root_api),
        "worker_api_ms_sum": sum(max(0, row.get("ms", 0)) for row in worker_api),
        "context_tokens_sum": sum(max(0, row.get("context_tokens", 0)) for row in api),
        "cache_read_tokens_sum": sum(
            max(0, row.get("cache_read_tokens", 0)) for row in api
        ),
        "request_bytes_sum": sum(max(0, row.get("req_bytes", 0)) for row in api),
        "response_bytes_sum": sum(max(0, row.get("resp_bytes", 0)) for row in api),
        "tool_calls": len(tools),
        "tool_errors": sum(bool(row.get("is_error")) for row in tools),
        "provider_retries": len(retries),
        "root_tool_calls": sum(not bool(row.get("from_sub")) for row in tools),
        "worker_tool_calls": sum(bool(row.get("from_sub")) for row in tools),
        "child_nodes": len(children),
        "child_providers": [row.get("provider") for row in children],
        "child_models": [row.get("model") for row in children],
        "shape_valid": (
            len(children) == 2
            and expected_children
            and expected_child_providers
            and expected_root
            and expected_worker_api
            and len(worker_api) >= 2
        ),
    }


def run_one(
    graff: Path, output_root: Path, task: Task, arm: Arm, repetition: int
) -> dict[str, Any]:
    root = output_root / "runs" / f"r{repetition}-{task.name}-{arm.name}"
    test_hash = initialize_workspace(root, task)
    env = os.environ.copy()
    controlled_path = os.pathsep.join(
        dict.fromkeys((str(Path(sys.executable).parent), "/usr/bin", "/bin"))
    )
    env.update(
        {
            "GRAFF_FLEET": "off",
            "GRAFF_BEHAVIOR_UPLOAD": "off",
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_NO_SMOLIFY": "1",
            "GRAFF_NO_CODEDB_GUARD": "1",
            "PATH": controlled_path,
        }
    )
    command = [
        str(graff),
        "--model", ROOT_MODEL,
        "--no-resume",
        "--yolo",
        "--json",
        "--no-telemetry",
        "--max-model-calls", "24",
        "--max-tool-calls", "48",
    ]
    if arm.worker_provider != ROOT_PROVIDER:
        command.extend(
            [
                "--subagent-provider", arm.worker_provider,
                "--allow-cross-provider-subagents",
            ]
        )
    if arm.worker_model != ROOT_MODEL or arm.worker_provider != ROOT_PROVIDER:
        command.extend(["--subagent-model", arm.worker_model])
    prompt = f"{COMMON_REQUEST}\n\n{task.request}"
    stdin = (
        json.dumps({"type": "set_effort", "level": "high"}) + "\n"
        + json.dumps({"type": "user", "text": prompt}) + "\n"
    )
    started = time.monotonic()
    timed_out = False
    try:
        proc = subprocess.run(
            command,
            cwd=root,
            env=env,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=600,
            check=False,
        )
        returncode, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        returncode = 124
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
    wall_ms = round((time.monotonic() - started) * 1000)
    checks = run_checks(task, root, test_hash)
    metrics = trace_metrics(root, arm)
    diff = subprocess.run(
        ["git", "diff", "--numstat"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    ).stdout
    changed_lines = 0
    for line in diff.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].isdigit():
            changed_lines += int(fields[0]) + int(fields[1])
    events = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            events.append(value)
    terminal = next(
        (event for event in reversed(events) if event.get("type") == "turn"),
        {},
    )
    return {
        "task": task.name,
        "arm": arm.name,
        "root_provider": ROOT_PROVIDER,
        "root_model": ROOT_MODEL,
        "worker_provider": arm.worker_provider,
        "worker_model": arm.worker_model,
        "repetition": repetition,
        "returncode": returncode,
        "timed_out": timed_out,
        "wall_ms": wall_ms,
        "changed_lines": changed_lines,
        "reported_cost_usd": terminal.get("cost_usd"),
        "checks": checks,
        "metrics": metrics,
        "stdout_tail": stdout[-4000:],
        "stderr_tail": stderr[-4000:],
        "workspace": str(root),
    }


def aggregate(rows: list[dict[str, Any]], arms: tuple[Arm, ...]) -> dict[str, Any]:
    result = {}
    for arm in arms:
        selected = [row for row in rows if row["arm"] == arm.name]
        correct = [row["checks"]["fully_correct"] for row in selected]
        shape = [row["metrics"]["shape_valid"] for row in selected]
        result[arm.name] = {
            "runs": len(selected),
            "fully_correct": sum(correct),
            "correctness_rate": sum(correct) / len(selected),
            "cases_passed": sum(row["checks"]["passed"] for row in selected),
            "cases_total": sum(row["checks"]["total"] for row in selected),
            "shape_valid": sum(shape),
            "median_wall_ms": statistics.median(row["wall_ms"] for row in selected),
            "median_api_ms_sum": statistics.median(
                row["metrics"]["api_ms_sum"] for row in selected
            ),
            "median_api_calls": statistics.median(
                row["metrics"]["api_calls"] for row in selected
            ),
            "median_tool_calls": statistics.median(
                row["metrics"]["tool_calls"] for row in selected
            ),
            "median_tool_errors": statistics.median(
                row["metrics"]["tool_errors"] for row in selected
            ),
            "median_provider_retries": statistics.median(
                row["metrics"]["provider_retries"] for row in selected
            ),
            "median_context_tokens_sum": statistics.median(
                row["metrics"]["context_tokens_sum"] for row in selected
            ),
            "median_changed_lines": statistics.median(
                row["changed_lines"] for row in selected
            ),
        }
    return result


def compare(rows: list[dict[str, Any]], arms: tuple[Arm, ...]) -> dict[str, Any]:
    by_arm = {
        arm.name: [row for row in rows if row["arm"] == arm.name]
        for arm in arms
    }
    baseline, shaped = (by_arm[arm.name] for arm in arms)
    def unit(row: dict[str, Any]) -> tuple[str, int]:
        return row["task"], row.get("repetition", 1)

    baseline_by_unit = {unit(row): row for row in baseline}
    shaped_by_unit = {unit(row): row for row in shaped}
    paired_units = sorted(set(baseline_by_unit) & set(shaped_by_unit))
    baseline = [baseline_by_unit[unit_id] for unit_id in paired_units]
    shaped = [shaped_by_unit[unit_id] for unit_id in paired_units]

    def total(selected: list[dict[str, Any]], field: str) -> int:
        if field == "wall_ms":
            return sum(row[field] for row in selected)
        return sum(row["metrics"][field] for row in selected)

    def delta(shaped_value: int, baseline_value: int) -> float | None:
        return (
            (shaped_value / baseline_value - 1) * 100
            if baseline_value
            else None
        )

    paired_wall_deltas = [
        delta(
            shaped_by_unit[unit_id]["wall_ms"],
            baseline_by_unit[unit_id]["wall_ms"],
        )
        for unit_id in paired_units
    ]
    def effective_correctness(row: dict[str, Any]) -> int:
        return (
            row["checks"]["passed"]
            if row["metrics"].get("shape_valid", True)
            else 0
        )

    baseline_correct = sum(effective_correctness(row) for row in baseline)
    shaped_correct = sum(effective_correctness(row) for row in shaped)
    baseline_shapes = sum(
        row["metrics"].get("shape_valid", True) for row in baseline
    )
    shaped_shapes = sum(
        row["metrics"].get("shape_valid", True) for row in shaped
    )
    baseline_tools = total(baseline, "tool_calls")
    shaped_tools = total(shaped, "tool_calls")
    provisional = (
        arms[1].name
        if shaped_correct > baseline_correct
        or (shaped_correct == baseline_correct and shaped_tools < baseline_tools)
        else arms[0].name
    )
    pairs = len(paired_units)
    return {
        "selection_policy": "correctness_first_then_tool_economy",
        "provisional_winner": provisional,
        "manual_promotion_required": (
            pairs < MINIMUM_PAIRS_FOR_PROMOTION
            or baseline_shapes != pairs
            or shaped_shapes != pairs
        ),
        "minimum_pairs_for_promotion": MINIMUM_PAIRS_FOR_PROMOTION,
        "observed_pairs": pairs,
        "correctness": {
            arms[0].name: baseline_correct,
            arms[1].name: shaped_correct,
        },
        "valid_shapes": {
            arms[0].name: baseline_shapes,
            arms[1].name: shaped_shapes,
        },
        "total_wall_ms": {
            arms[0].name: total(baseline, "wall_ms"),
            arms[1].name: total(shaped, "wall_ms"),
        },
        "total_wall_delta_pct": delta(
            total(shaped, "wall_ms"), total(baseline, "wall_ms")
        ),
        "median_paired_wall_delta_pct": (
            statistics.median(value for value in paired_wall_deltas if value is not None)
            if paired_wall_deltas
            else None
        ),
        "faster_pairs": sum(
            value is not None and value < 0 for value in paired_wall_deltas
        ),
        "total_tool_calls": {
            arms[0].name: baseline_tools,
            arms[1].name: shaped_tools,
        },
        "tool_call_delta_pct": delta(shaped_tools, baseline_tools),
        "api_call_delta_pct": delta(
            total(shaped, "api_calls"), total(baseline, "api_calls")
        ),
        "context_token_delta_pct": delta(
            total(shaped, "context_tokens_sum"),
            total(baseline, "context_tokens_sum"),
        ),
        "response_byte_delta_pct": delta(
            total(shaped, "response_bytes_sum"),
            total(baseline, "response_bytes_sum"),
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graff", default="zig-out/bin/graff")
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--seed", type=int, default=246)
    parser.add_argument("--output-root")
    parser.add_argument("--task-set", choices=("core", "frontend", "all"), default="core")
    parser.add_argument("--tasks", nargs="*", choices=[task.name for task in ALL_TASKS])
    parser.add_argument(
        "--worker",
        action="append",
        metavar="PROVIDER:MODEL",
        help="exactly two root-worker arms; defaults to Codex Sol and Terra",
    )
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    graff = Path(args.graff).expanduser().resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")
    if args.output_root:
        output_root = Path(args.output_root).expanduser().resolve()
        output_root.mkdir(parents=True, exist_ok=False)
    else:
        output_root = Path(
            tempfile.mkdtemp(
                prefix=f"codegraff-model-shape-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-"
            )
        )
    task_pool = {
        "core": CORE_TASKS,
        "frontend": FRONTEND_TASKS,
        "all": ALL_TASKS,
    }[args.task_set]
    tasks = tuple(task for task in task_pool if not args.tasks or task.name in args.tasks)
    if not tasks:
        parser.error("selected task set is empty")
    worker_specs = args.worker or (
        f"{ROOT_PROVIDER}:{ROOT_MODEL}",
        f"{ROOT_PROVIDER}:{WORKER_MODEL}",
    )
    if len(worker_specs) != 2:
        parser.error("--worker must be supplied exactly twice")
    try:
        arms = tuple(arm_for(spec) for spec in worker_specs)
    except ValueError as exc:
        parser.error(str(exc))
    if arms[0].name == arms[1].name:
        parser.error("worker arms must be distinct")
    schedule = []
    rng = random.Random(args.seed)
    for repetition in range(1, args.repetitions + 1):
        shuffled = list(tasks)
        rng.shuffle(shuffled)
        ordered_arms = arms if repetition % 2 else tuple(reversed(arms))
        for task in shuffled:
            schedule.extend((task, arm, repetition) for arm in ordered_arms)
    rows = []
    for index, (task, arm, repetition) in enumerate(schedule, 1):
        print(
            f"[{index}/{len(schedule)}] {task.name} {arm.name} repetition {repetition}",
            flush=True,
        )
        row = run_one(graff, output_root, task, arm, repetition)
        rows.append(row)
        print(
            "  "
            f"correct={row['checks']['passed']}/{row['checks']['total']} "
            f"shape={row['metrics']['shape_valid']} "
            f"wall={row['wall_ms'] / 1000:.1f}s "
            f"api={row['metrics']['api_calls']} "
            f"tools={row['metrics']['tool_calls']}",
            flush=True,
        )
    report = {
        "schema": "codegraff.model-shape-benchmark.v1",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "graff": str(graff),
        "seed": args.seed,
        "repetitions": args.repetitions,
        "task_set": args.task_set,
        "tasks": [task.name for task in tasks],
        "task_niches": {task.name: task.niche for task in tasks},
        "privacy": {
            "workspace": "synthetic",
            "external_telemetry": False,
            "behavior_upload": False,
        },
        "arms": [asdict(arm) for arm in arms],
        "runs": rows,
        "aggregate": aggregate(rows, arms),
        "quality_diversity": quality_diversity(rows, arms, tasks),
    }
    report["comparison"] = compare(rows, arms)
    report_path = output_root / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("\n" + json.dumps(report["aggregate"], indent=2))
    print("\nquality diversity:\n" + json.dumps(report["quality_diversity"], indent=2))
    print("\ncomparison:\n" + json.dumps(report["comparison"], indent=2))
    print(f"\nreport: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
