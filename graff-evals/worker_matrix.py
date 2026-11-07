#!/usr/bin/env python3
"""Prepare or run an opt-in private root/worker matrix on paired fixture tasks."""
import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

import measurement
import worker_matrix_measure as metrics

EVALS = Path(__file__).resolve().parent
REPO = EVALS.parent
NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
LIMITS = "Work only inside this fixture workspace. Never edit tests, read parent directories or credentials, access external services, install anything, use MCP or peer messaging, invoke other coding CLIs, create goals, commit/push, or change model/provider/effort. Do not set model/provider/tier overrides for workers. No nested or replacement workers."


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)


def relative(value):
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("Expected a nonempty relative path")
    return path


def validate(manifest):
    for key in ("repetitions", "max_model_calls", "max_tool_calls"):
        if type(manifest[key]) is not int or manifest[key] < 1:
            raise ValueError(f"{key} must be a positive integer")
    arms = manifest["arms"]
    if not arms or len({a["id"] for a in arms}) != len(arms):
        raise ValueError("Arms must have unique ids")
    for arm in arms:
        if not NAME.fullmatch(arm["id"]):
            raise ValueError("Unsafe arm id")
        for route in (arm["root"], arm.get("worker")):
            if route is not None and any(not isinstance(route[k], str) or not route[k]
                                         or any(c.isspace() for c in route[k])
                                         for k in ("provider", "model")):
                raise ValueError("Routes require explicit provider and model")
        for rates in arm.get("prices", {}).values():
            if not rates.get("source") or type(rates["max_input"]) is not int or rates["max_input"] < 1:
                raise ValueError("Rates require a source and positive per-request input limit")
            for key in ("input", "cached", "write", "write_1h", "output"):
                value = Decimal(str(rates[key]))
                if not value.is_finite() or value < 0:
                    raise ValueError("Rates must be finite and nonnegative")
    if not manifest["tasks"] or len({p["team"] for p in manifest["tasks"]}) != len(manifest["tasks"]):
        raise ValueError("Task pairs must be nonempty and unique")
    for pair in manifest["tasks"]:
        if not all(NAME.fullmatch(pair[k]) for k in ("team", "solo")):
            raise ValueError("Unsafe task id")
        if type(pair["workers"]) is not int or pair["workers"] < 1:
            raise ValueError("Each task requires a positive worker count")
    for entry in manifest.get("auth_files", []):
        relative(entry["destination"])
        if not Path(entry["source"]).expanduser().is_file():
            raise ValueError("Explicit authentication file missing")
    for name in manifest.get("auth_env", []):
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name) or not os.environ.get(name):
            raise ValueError("Explicit authentication environment variable missing")
    limit = Decimal(str(manifest["cost_stop_usd"]))
    if not limit.is_finite() or limit <= 0:
        raise ValueError("cost_stop_usd must be positive")


def check(workspace, task, task_root, env):
    check_env = {**env, "TASK_ROOT": str(task_root)}
    try:
        result = subprocess.run(task["check"], shell=True, cwd=workspace, env=check_env,
                                capture_output=True, text=True, timeout=60)
        return {"returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"returncode": None, "timed_out": True}


def schedule(manifest):
    slots = []
    for rep in range(manifest["repetitions"]):
        for index, pair in enumerate(manifest["tasks"]):
            rotation = (rep + index) % len(manifest["arms"])
            arms = manifest["arms"][rotation:] + manifest["arms"][:rotation]
            slots.extend({"task": pair["team"], "rep": rep + 1, "arm": a["id"]} for a in arms)
    return slots


def prepare(manifest_path, binary, root):
    manifest = json.loads(manifest_path.read_text())
    validate(manifest)
    if root.is_relative_to(REPO):
        raise ValueError("Output must be outside the repository")
    tasks = {t["id"]: t for p in (EVALS / "tasks").glob("*.json")
             if (t := json.loads(p.read_text())).get("suite") in ("subagents", "subagents-solo")}
    root.mkdir(mode=0o700)
    save(root / "manifest.json", manifest)
    shutil.copyfile(binary, root / "graff")
    (root / "graff").chmod(0o700)
    receipt = {"schedule": schedule(manifest), "binary_sha256": digest(root / "graff"),
               "manifest_sha256": digest(root / "manifest.json"), "tasks": {},
               "runner_sha256": digest(Path(__file__)),
               "measurement_sha256": digest(Path(metrics.__file__))}
    for pair in manifest["tasks"]:
        team, solo = tasks[pair["team"]], tasks[pair["solo"]]
        if (team["suite"] != "subagents" or solo["suite"] != "subagents-solo"
                or solo.get("counterfactual_of") != team["id"]
                or team["files_dir"] != solo["files_dir"] or team["check"] != solo["check"]):
            raise ValueError("Counterfactual tasks must share fixture and grader")
        folder = root / "inputs" / pair["team"]
        folder.mkdir(parents=True, mode=0o700)
        fixture = EVALS / relative(team["files_dir"])
        if not fixture.resolve().is_relative_to(EVALS.resolve()):
            raise ValueError("Fixture must be inside the eval tree")
        shutil.copytree(fixture, folder / "fixture",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".git"))
        graders = re.findall(r'\$TASK_ROOT/(hidden/[^\s"\x27;]+)', team["check"])
        if not graders:
            raise ValueError("Paired task requires a held-out grader")
        for name in graders:
            destination = folder / relative(name)
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.copyfile(EVALS / relative(name), destination)
        frozen = {**pair, "team_task": team, "solo_task": solo}
        save(folder / "task.json", frozen)
        baseline = check(folder / "fixture", team, folder, {"PATH": os.environ.get("PATH", "")})
        save(folder / "initial-check.json", baseline)
        if baseline["returncode"] == 0:
            raise ValueError("Fixture unexpectedly already solved")
        receipt["tasks"][pair["team"]] = {
            str(p.relative_to(folder)): digest(p) for p in folder.rglob("*")
            if p.is_file() and "__pycache__" not in p.parts}
    save(root / "receipt.json", receipt)
    for p in root.rglob("*"):
        p.chmod(0o700 if p.is_dir() or p == root / "graff" else 0o600)


def run_one(root, manifest, receipt, slot):
    inputs = root / "inputs" / slot["task"]
    for name, expected in receipt["tasks"][slot["task"]].items():
        if digest(inputs / name) != expected:
            raise ValueError("Frozen task input changed")
    task_data = json.loads((inputs / "task.json").read_text())
    arm = next(a for a in manifest["arms"] if a["id"] == slot["arm"])
    task = task_data["team_task" if arm.get("worker") else "solo_task"]
    output = root / "runs" / f'{slot["task"]}-r{slot["rep"]}-{slot["arm"]}'
    output.mkdir(parents=True, mode=0o700)
    workspace, home = output / "workspace", output / "home"
    shutil.copytree(inputs / "fixture", workspace, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    measurement.isolate_git(str(workspace))
    protected = measurement.verifier_snapshot(str(workspace), task, str(inputs))
    if task_data.get("freeze_all_inputs"):
        protected.update({str(workspace / name.removeprefix("fixture/")): value
                          for name, value in receipt["tasks"][slot["task"]].items()
                          if name.startswith("fixture/")})
    home.mkdir(mode=0o700)
    for entry in manifest.get("auth_files", []):
        destination = home / relative(entry["destination"])
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(Path(entry["source"]).expanduser(), destination)
        destination.chmod(0o600)
    empty_mcp = home / "empty-mcp.json"
    empty_mcp.write_text('{"mcpServers":{}}')
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", *manifest.get("auth_env", []))
           if k in os.environ}
    env.update(HOME=str(home), USERPROFILE=str(home), PWD=str(workspace),
               XDG_CONFIG_HOME=str(home / ".config"), XDG_CACHE_HOME=str(home / ".cache"),
               GRAFF_MCP_CONFIG=str(empty_mcp), GRAFF_FLEET="off", GRAFF_NO_PLUGINS="1",
               GRAFF_NO_TELEMETRY="1", GRAFF_BEHAVIOR_UPLOAD="off", GRAFF_NO_SMOLIFY="1",
               GRAFF_LEARNING_PRIVACY="local", NO_COLOR="1")
    root_route = arm["root"]
    command = [str(root / "graff"), "--json", "--old", "--yolo", "--no-lean",
               "--model", root_route["provider"] + "/" + root_route["model"],
               "--no-subagent-tier", "--no-telemetry", "--learning-privacy", "local",
               "--max-model-calls", str(manifest["max_model_calls"]),
               "--max-run-tool-calls", str(manifest["max_tool_calls"])]
    worker = arm.get("worker")
    if worker:
        command += ["--subagent-provider", worker["provider"], "--subagent-model", worker["model"]]
        if worker["provider"] != root_route["provider"]:
            command.append("--allow-cross-provider-subagents")
    policy = (f"Use exactly {task_data['workers']} background workers. Launch all before collecting "
              "them, do independent root work meanwhile, collect actual results with agent_output, "
              "review and repair their output yourself, and run visible tests. Pass on all limits."
              if worker else "Do all work yourself. Do not spawn subagents or workflows.")
    prompt = task["prompt"] + "\n\n" + LIMITS + "\n" + policy
    save(output / "invocation.json", {"command": command, "prompt": prompt})
    start = time.perf_counter()
    process = subprocess.Popen(command, cwd=workspace, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True)
    save(output / "process.json", {"pid": process.pid})
    timed_out = False
    try:
        stdout, stderr = process.communicate(json.dumps({"type": "user", "text": prompt}) + "\n",
                                             timeout=task["timeout_s"])
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    seconds = time.perf_counter() - start
    measurement.kill_session(process.pid)
    (output / "stdout.jsonl").write_text(stdout)
    (output / "stderr.txt").write_text(stderr)
    events, malformed = metrics.read_rows(output / "stdout.jsonl")
    traces = []
    for path in (workspace / ".graff/traces").glob("*.jsonl"):
        rows, errors = metrics.read_rows(path)
        traces.extend(rows)
        malformed += errors
    observed = metrics.measure(events, traces, arm, task_data["workers"], malformed)
    checks = check(workspace, task, inputs, {"PATH": os.environ.get("PATH", "")})
    verifiers_ok = measurement.verifiers_unchanged(protected)
    result = {**slot, **observed, "seconds": seconds, "returncode": process.returncode,
              "timed_out": timed_out, "check": checks, "verifiers_unchanged": verifiers_ok}
    result["passed"] = bool(checks["returncode"] == 0 and verifiers_ok and observed["routing_ok"]
                            and observed["delegation_ok"] and observed["turn_complete"]
                            and process.returncode == 0 and not timed_out)
    save(output / "result.json", result)
    return result


def batch(root):
    manifest = json.loads((root / "manifest.json").read_text())
    validate(manifest)
    receipt = json.loads((root / "receipt.json").read_text())
    if (root / "results.json").exists() or (root / "runs").exists():
        raise ValueError("Never restart or overwrite an attempted matrix")
    for path, field in ((root / "graff", "binary_sha256"),
                        (root / "manifest.json", "manifest_sha256"),
                        (Path(__file__), "runner_sha256"),
                        (Path(metrics.__file__), "measurement_sha256")):
        if digest(path) != receipt[field]:
            raise ValueError("Prepared executable, config or measurement changed")
    results, spent = [], Decimal(0)
    for slot in receipt["schedule"]:
        if digest(root / "graff") != receipt["binary_sha256"]:
            raise ValueError("Prepared executable changed")
        result = run_one(root, manifest, receipt, slot)
        results.append(result)
        save(root / "results.json", results)
        save(root / "summary.json", {"groups": metrics.summarize(results),
                                     "limitations": "Exploratory paired fixtures; native reasoning defaults, uncontrolled cache. Costs include failed trials; incomplete means stay unknown."})
        print(json.dumps({k: result[k] for k in ("task", "rep", "arm", "passed", "seconds",
                                                 "native_full_cost_usd", "api_equivalent_estimate_usd")}),
              flush=True)
        reason = None
        cost = result["native_full_cost_usd"]
        if cost is None:
            cost = result["api_equivalent_estimate_usd"]
        if not result["routing_ok"] or not result["token_usage_complete"]:
            reason = "Route mismatch or incomplete token usage"
        elif cost is None:
            reason = "Unknown cost; supply a documented hypothetical rate snapshot separately"
        else:
            spent += Decimal(str(cost))
            if spent >= Decimal(str(manifest["cost_stop_usd"])):
                reason = "Between-run cost stop; not a provider-side hard cap"
        if reason:
            save(root / "stopped.json", {"after": slot, "reason": reason})
            break
    save(root / "completion.json", {"attempted": len(results), "planned": len(receipt["schedule"]),
                                    "budget_accounting_subtotal_usd": str(spent),
                                    "budget_accounting": "Native full cost when known, otherwise explicit rate estimate; never a settled bill."})
    for path in root.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o700 if path.is_dir() or path == root / "graff" else 0o600)


def main():
    os.umask(0o077)
    if os.name != "posix":
        raise SystemExit("This local fixture runner requires POSIX process sessions")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="private matrix manifest (prepare only)")
    parser.add_argument("--binary", type=Path, help="explicit installed executable to freeze")
    parser.add_argument("--output-root", type=Path, help="new private directory outside the repository")
    parser.add_argument("--run", type=Path, help="explicit opt-in to execute a prepared matrix")
    parser.add_argument("--summarize", type=Path, help="read saved results offline; never execute models")
    args = parser.parse_args()
    if args.summarize and not any((args.run, args.manifest, args.binary, args.output_root)):
        results = json.loads((args.summarize.expanduser().resolve() / "results.json").read_text())
        print(json.dumps({
            "groups": metrics.summarize(results),
            "limitations": "Offline summary of saved results, not fresh validation. Role costs are explicit rate estimates, not settled charges. Includes failed trials; unknown costs remain unknown.",
        }, indent=2))
    elif args.run and not args.summarize and not any((args.manifest, args.binary, args.output_root)):
        batch(args.run.expanduser().resolve())
    elif not args.run and not args.summarize and all((args.manifest, args.binary, args.output_root)):
        root = args.output_root.expanduser().resolve()
        prepare(args.manifest.expanduser().resolve(), args.binary.expanduser().resolve(), root)
        print(root)
    else:
        parser.error("Use --manifest/--binary/--output-root to prepare, --run to execute, or --summarize to read saved results")


if __name__ == "__main__":
    main()
