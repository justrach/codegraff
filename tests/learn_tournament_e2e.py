#!/usr/bin/env python3
"""Four-arm concurrency, winner-only holdout, and five-grade regression."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time

from learn_e2e import (
    GradeCapture,
    invoke,
    json_bytes,
    raw_sha256,
    run_id_from,
    status,
    write_forged_object,
    write_interpreter_shim,
    write_posix_shebang,
    write_private,
)


MUTATOR = r'''import hashlib, json, os, pathlib, sys, time
operation, request_path, response_path = sys.argv[1:4]
assert operation == "mutate"
request = json.loads(pathlib.Path(request_path).read_text())
index = request["candidate_index"]
barrier = pathlib.Path(os.environ["TOURNAMENT_BARRIER"])
(barrier / f"mutation-{index}").write_text("started")
deadline = time.monotonic() + 10
while len(list(barrier.glob("mutation-*"))) != 4:
    assert time.monotonic() < deadline, "mutations did not run concurrently"
    time.sleep(0.01)
parent = pathlib.Path(request["parent"]["path"]).read_text()
child = parent.rstrip() + f"\n\nTournament variant {index}.\n"
child_bytes = child.encode()
pathlib.Path(request["child_path"]).write_bytes(child_bytes)
response = {
    "schema": "codegraff.learn.mutation.response.v1",
    "trial_id": request["trial_id"],
    "candidate_index": index,
    "parent_id": request["parent"]["id"],
    "child_path": request["child_path"],
    "child_sha256": hashlib.sha256(child_bytes).hexdigest(),
    "description": f"fixture arm {index}",
}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''


EVALUATOR = r'''import hashlib, json, os, pathlib, sys, time
operation, request_path, response_path = sys.argv[1:4]
request = json.loads(pathlib.Path(request_path).read_text())
suite_bytes = pathlib.Path(request["suite_path"]).read_bytes()
assert hashlib.sha256(suite_bytes).hexdigest() == request["suite_sha256"]
suite = json.loads(suite_bytes)
barrier = pathlib.Path(os.environ["TOURNAMENT_BARRIER"])

if operation == "baseline":
    assert suite["suite_id"] == "tournament-primary"
    (barrier / "baseline-once").open("x").write("parent")
    pairs = [{
        "case_id": pair["case_id"], "seed": pair["seed"],
        "pass": False, "score_ppm": 0, "cost_micros": 100,
        "tool_calls_measured": True, "tool_calls": 10,
    } for pair in request["pairs"]]
    response = {
        "schema": "codegraff.learn.primary-baseline.response.v1",
        "trial_id": request["trial_id"], "cohort_id": request["cohort_id"],
        "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent"]["id"], "pairs": pairs,
    }
    (barrier / "baseline-done").write_text("done")
elif operation == "evaluate_primary":
    assert suite["suite_id"] == "tournament-primary"
    assert (barrier / "baseline-done").is_file()
    index = request["candidate_index"]
    baseline = json.loads(pathlib.Path(request["baseline"]["path"]).read_text())
    (barrier / f"primary-start-{index}").write_text("started")
    deadline = time.monotonic() + 10
    while len(list(barrier.glob("primary-start-*"))) != 4:
        assert time.monotonic() < deadline, "primary evaluations did not run concurrently"
        time.sleep(0.01)
    retry_marker = barrier / f"primary-retried-{index}"
    if index == 0 and not retry_marker.exists():
        retry_marker.write_text("retry")
        raise SystemExit(17)
    calls = [9, 7, 3, 5][index]
    assert [(p["case_id"], p["seed"]) for p in baseline["pairs"]] == [
        (p["case_id"], p["seed"]) for p in request["pairs"]
    ]
    pairs = [{
        "case_id": parent["case_id"], "seed": parent["seed"],
        "parent_pass": parent["pass"], "child_pass": True,
        "parent_score_ppm": parent["score_ppm"], "child_score_ppm": 1000000,
        "parent_cost_micros": parent["cost_micros"], "child_cost_micros": calls,
        "tool_calls_measured": parent["tool_calls_measured"],
        "parent_tool_calls": parent["tool_calls"], "child_tool_calls": calls,
    } for parent in baseline["pairs"]]
    response = {
        "schema": "codegraff.learn.primary-evaluation.response.v1",
        "trial_id": request["trial_id"], "candidate_index": index,
        "cohort_id": request["cohort_id"], "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent_id"], "child_id": request["child"]["id"],
        "pairs": pairs,
    }
    (barrier / f"primary-done-{index}").write_text("done")
elif operation == "evaluate":
    assert suite["suite_id"] == "tournament-fresh-holdout"
    index = request["candidate_index"]
    assert len(list(barrier.glob("primary-done-*"))) == 4, "holdout started before the primary barrier"
    (barrier / "holdout-once").open("x").write(str(index))
    calls = [9, 7, 3, 5][index]
    pairs = [{
        "case_id": pair["case_id"], "seed": pair["seed"],
        "parent_pass": False, "child_pass": True,
        "parent_score_ppm": 0, "child_score_ppm": 1000000,
        "parent_cost_micros": 100, "child_cost_micros": calls,
        "tool_calls_measured": True, "parent_tool_calls": 10, "child_tool_calls": calls,
    } for pair in request["pairs"]]
    response = {
        "schema": "codegraff.learn.evaluation.response.v1",
        "trial_id": request["trial_id"], "candidate_index": index,
        "cohort_id": request["cohort_id"], "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent"]["id"], "child_id": request["child"]["id"],
        "pairs": pairs,
    }
else:
    raise AssertionError(f"unexpected operation {operation}")
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''


def attrs(record: dict) -> dict:
    return {item["key"]: next(iter(item["value"].values())) for item in record["attributes"]}


def exercise(graff: Path, root: Path) -> None:
    workspace = root / "workspace"
    tools = root / "tools"
    barrier = root / "barrier"
    for path in (workspace, tools, barrier):
        path.mkdir(mode=0o700)

    python = Path(sys.executable).resolve()
    if sys.platform == "win32":
        mutator, _ = write_interpreter_shim(tools, "tournament-mutator", python, MUTATOR)
    else:
        mutator_path = tools / "tournament-mutator.py"
        write_posix_shebang(mutator_path, python, MUTATOR)
        mutator = {"program": str(mutator_path.resolve()), "sha256": raw_sha256(mutator_path)}
    evaluator, _ = write_interpreter_shim(tools, "tournament-evaluator", python, EVALUATOR)
    mutator["pass_env"] = ["TOURNAMENT_BARRIER"]
    evaluator["pass_env"] = ["TOURNAMENT_BARRIER"]

    primary = tools / "primary.json"
    holdout = tools / "holdout.json"
    write_private(primary, json_bytes({
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "tournament-primary",
        "cases": [{"id": f"primary-{index}"} for index in range(8)],
    }))
    write_private(holdout, json_bytes({
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "tournament-fresh-holdout",
        "cases": [{"id": f"holdout-{index}"} for index in range(8)],
    }))
    parent = root / "parent.md"
    write_private(parent, b"Initial tournament policy.\n")
    config_path = root / "config.json"
    config = {
        "schema": "codegraff.learn.config.v1",
        "agent_name": "secret-internal-agent-name",
        "mutation_instruction": "produce one indexed tournament variant",
        "mutator": mutator,
        "evaluator": evaluator,
        "evaluation_suite": {"path": str(primary.resolve()), "sha256": raw_sha256(primary)},
        "holdout_suite": {"path": str(holdout.resolve()), "sha256": raw_sha256(holdout)},
        "gate": {
            "alpha_ppm": 50000,
            "minimum_delta_ppm": 100000,
            "minimum_pairs": 8,
            "require_all_candidates": True,
            "default_candidates": 4,
            "default_repetitions": 1,
        },
        "auto": {"enabled": False},
        "cohort": {
            "provider": "fixture", "model": "fixture", "task_family": "tournament",
            "adapter_version": "v2", "verifier_version": "v2",
        },
    }
    write_private(config_path, json_bytes(config))

    key_path = root / ".simple-harness" / "score.key"
    key_path.parent.mkdir(mode=0o700)
    write_private(key_path, b"fixture-score-key\n")
    env = os.environ.copy()
    env.update({
        "HOME": str(root),
        "GRAFF_BEHAVIOR_TRACE": "0",
        "TOURNAMENT_BARRIER": str(barrier),
    })
    env.pop("GRAFF_NO_TELEMETRY", None)

    GradeCapture.payloads = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), GradeCapture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env["GRAFF_OTEL_ENDPOINT"] = f"http://127.0.0.1:{server.server_port}"
    try:
        invoke(graff, workspace, env, "init", "--parent", str(parent.resolve()), "--config", str(config_path.resolve()))
        output = invoke(graff, workspace, env, "run", "--candidates", "4", "--submit").stdout
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    run_id = run_id_from(output)
    record_path = workspace / ".graff" / "learn" / "runs" / f"{run_id}.json"
    record = json.loads(record_path.read_text())
    assert record["schema"] == "codegraff.learn.run.v3"
    assert record["primary_baseline"] is not None
    assert len(record["candidates"]) == 4
    assert (barrier / "primary-retried-0").is_file()
    assert sum(candidate["primary"] is not None for candidate in record["candidates"]) == 4
    assert sum(candidate["holdout"] is not None for candidate in record["candidates"]) == 1
    winner = next(candidate for candidate in record["candidates"] if candidate["holdout"] is not None)
    assert winner["primary"]["child_tool_calls"] == 24
    parent_projections = {
        (
            candidate["primary"]["parent_passes"],
            candidate["primary"]["parent_tool_calls"],
            candidate["primary"]["parent_cost_micros"],
        )
        for candidate in record["candidates"]
    }
    assert parent_projections == {(0, 80, 800)}
    assert winner["genome_id"] == record["primary_winner_genome_id"] == record["selected_genome_id"]
    assert "manual promotion:" in output
    assert status(graff, workspace, env)["generation"] == 0
    assert len(list(barrier.glob("mutation-*"))) == 4
    assert (barrier / "baseline-once").read_text() == "parent"
    assert len(list(barrier.glob("primary-done-*"))) == 4
    assert (barrier / "holdout-once").read_text() == "2"

    assert len(GradeCapture.payloads) == 1
    encoded = json.dumps(GradeCapture.payloads[0], separators=(",", ":"))
    assert "secret-internal-agent-name" not in encoded
    assert "Tournament variant" not in encoded and "prompt_text" not in encoded
    records = GradeCapture.payloads[0]["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
    assert len(records) == 5
    stages = Counter(attrs(item)["judge_id"] for item in records)
    assert stages == {"learn-primary-v2": 4, "learn-holdout-v2": 1}
    hashes = Counter(attrs(item)["eval_set_hash"] for item in records)
    assert hashes == {raw_sha256(primary): 4, raw_sha256(holdout): 1}

    # Parent fields in every primary response are a cryptographic projection
    # of the one shared baseline. Re-addressing a forged response and run must
    # still fail verification before it can promote anything.
    learn_root = workspace / ".graff" / "learn"
    forged = copy.deepcopy(record)
    response_id = forged["candidates"][0]["primary"]["response_evidence_id"]
    response = json.loads((learn_root / "evidence" / f"{response_id}.json").read_text())
    response["pairs"][0]["parent_tool_calls"] += 1
    forged_response_id = write_forged_object(
        learn_root / "evidence", "codegraff-learn/evidence/v1", response,
    )
    forged["candidates"][0]["primary"]["response_evidence_id"] = forged_response_id
    forged_run_id = write_forged_object(learn_root / "runs", "codegraff-learn/run/v1", forged)
    rejected = invoke(graff, workspace, env, "promote", forged_run_id, succeeds=False)
    assert "BaselineProjectionMismatch" in rejected.stderr
    assert status(graff, workspace, env)["generation"] == 0

    # The untampered v3 evidence remains fully verifiable and promotable.
    invoke(graff, workspace, env, "promote", run_id)
    assert status(graff, workspace, env)["generation"] == 1
    assert json.loads(invoke(graff, workspace, env, "verify").stdout)["integrity"] == "ok"

    # A ranked but underpowered primary is persisted without exposing the
    # hidden suite at all.
    ineligible_workspace = root / "workspace-ineligible"
    ineligible_barrier = root / "barrier-ineligible"
    ineligible_workspace.mkdir(mode=0o700)
    ineligible_barrier.mkdir(mode=0o700)
    ineligible_config = copy.deepcopy(config)
    ineligible_config["gate"]["minimum_pairs"] = 9
    ineligible_config_path = root / "config-ineligible.json"
    write_private(ineligible_config_path, json_bytes(ineligible_config))
    ineligible_env = {**env, "TOURNAMENT_BARRIER": str(ineligible_barrier)}
    invoke(
        graff, ineligible_workspace, ineligible_env, "init",
        "--parent", str(parent.resolve()), "--config", str(ineligible_config_path.resolve()),
    )
    ineligible_output = invoke(graff, ineligible_workspace, ineligible_env, "run", "--candidates", "4").stdout
    ineligible_record = json.loads(
        ineligible_workspace.joinpath(
            ".graff", "learn", "runs", f"{run_id_from(ineligible_output)}.json",
        ).read_text()
    )
    assert ineligible_record["primary_winner_genome_id"] is not None
    assert ineligible_record["selected_genome_id"] is None
    assert all(candidate["holdout"] is None for candidate in ineligible_record["candidates"])
    assert not (ineligible_barrier / "holdout-once").exists()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    graff = args.graff.resolve()
    root = Path(tempfile.mkdtemp(prefix="codegraff-learn-tournament."))
    try:
        exercise(graff, root)
    except Exception:
        print(f"tournament E2E failed; fixture preserved at {root}", file=sys.stderr)
        raise
    if args.keep:
        print(f"tournament E2E passed; fixture preserved at {root}")
    else:
        shutil.rmtree(root)
        print("tournament E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
