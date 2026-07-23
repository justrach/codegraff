#!/usr/bin/env python3
"""Four-arm concurrency, winner-only holdout, and five-grade regression."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import hmac
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time

from learning_receipt_assertions import assert_learning_records
from learn_tournament_fixtures import MUTATOR

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
        "behavior_measured": True, "behavior_score_ppm": 500000,
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
    attempt_path = barrier / f"primary-attempts-{index}"
    attempts = int(attempt_path.read_text()) if attempt_path.exists() else 0
    attempt_path.write_text(str(attempts + 1))
    if (barrier / f"fail-primary-{index}").exists():
        raise SystemExit(29)
    retry_marker = barrier / f"primary-retried-{index}"
    if index == 0 and not retry_marker.exists():
        retry_marker.write_text("retry")
        raise SystemExit(17)
    calls = [9, 7, 3, 5][index]
    behavior_score = [900000, 950000, 800000, 1000000][index]
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
        "behavior_measured": parent["behavior_measured"],
        "parent_behavior_score_ppm": parent["behavior_score_ppm"],
        "child_behavior_score_ppm": behavior_score,
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
    holdout_marker = barrier / "holdout-once"
    if holdout_marker.exists():
        assert holdout_marker.read_text() == str(index), "resume changed the holdout winner"
    else:
        holdout_marker.write_text(str(index))
    holdout_attempts = barrier / "holdout-attempts"
    attempt_count = int(holdout_attempts.read_text()) if holdout_attempts.exists() else 0
    holdout_attempts.write_text(str(attempt_count + 1))
    if (barrier / "fail-holdout").exists():
        raise SystemExit(23)
    calls = [9, 7, 3, 5][index]
    behavior_score = [900000, 950000, 800000, 1000000][index]
    pairs = [{
        "case_id": pair["case_id"], "seed": pair["seed"],
        "parent_pass": False, "child_pass": True,
        "parent_score_ppm": 0, "child_score_ppm": 1000000,
        "parent_cost_micros": 100, "child_cost_micros": calls,
        "tool_calls_measured": True, "parent_tool_calls": 10, "child_tool_calls": calls,
        "behavior_measured": True,
        "parent_behavior_score_ppm": 500000, "child_behavior_score_ppm": behavior_score,
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
    assert winner["primary"]["child_behavior_score_ppm"] == 800000
    assert max(candidate["primary"]["child_behavior_score_ppm"] for candidate in record["candidates"]) == 1000000
    assert all(
        candidate["primary"]["correctness_regressions"] == 0
        for candidate in record["candidates"]
    )
    parent_projections = {
        (
            candidate["primary"]["parent_passes"],
            candidate["primary"]["parent_tool_calls"],
            candidate["primary"]["parent_cost_micros"],
            candidate["primary"]["parent_behavior_score_ppm"],
        )
        for candidate in record["candidates"]
    }
    assert parent_projections == {(0, 80, 800, 500000)}
    assert winner["genome_id"] == record["primary_winner_genome_id"] == record["selected_genome_id"]
    assert "manual promotion:" in output
    assert "PRIVATE_MUTATION_DESCRIPTION" not in output
    assert status(graff, workspace, env)["generation"] == 0
    assert len(list(barrier.glob("mutation-*"))) == 4
    assert (barrier / "mutator-retried-0").is_file()
    assert [(barrier / f"mutator-attempts-{index}").read_text() for index in range(4)] == ["2", "1", "1", "1"]
    assert (barrier / "baseline-once").read_text() == "parent"
    assert len(list(barrier.glob("primary-done-*"))) == 4
    assert (barrier / "holdout-once").read_text() == "2"
    assert [(barrier / f"primary-attempts-{index}").read_text() for index in range(4)] == ["2", "1", "1", "1"]
    assert (barrier / "holdout-attempts").read_text() == "1"

    # A consumed holdout makes a new trial impossible, so reject it before
    # spending another mutation or evaluation call.
    adapter_attempts = [
        (barrier / f"mutator-attempts-{index}").read_text() for index in range(4)
    ]
    consumed = invoke(graff, workspace, env, "run", "--candidates", "4", succeeds=False)
    assert "HoldoutConsumed" in consumed.stderr
    assert adapter_attempts == [
        (barrier / f"mutator-attempts-{index}").read_text() for index in range(4)
    ]

    assert len(GradeCapture.payloads) == 1
    encoded = json.dumps(GradeCapture.payloads[0], separators=(",", ":"))
    assert "secret-internal-agent-name" not in encoded
    assert "Tournament variant" not in encoded and "prompt_text" not in encoded
    resource_attrs = GradeCapture.payloads[0]["resourceLogs"][0]["resource"]["attributes"]
    assert {item["key"] for item in resource_attrs} == {"client.name"}
    records = GradeCapture.payloads[0]["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
    assert len(records) == 5
    key = key_path.read_bytes().strip()
    message = f"codegraff.learn.delete.v1\n{run_id}\n{record['nonce']}".encode()
    delete_token = hmac.new(key, message, hashlib.sha256).hexdigest()
    assert_learning_records(records, run_id, key, 4, delete_token)
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

    # Statistical grouping is suite-owned. Re-addressing a request with a
    # forged unit ID must not let stored evidence collapse or inflate power.
    forged_units = copy.deepcopy(record)
    request_id = forged_units["candidates"][0]["primary"]["request_evidence_id"]
    request = json.loads((learn_root / "evidence" / f"{request_id}.json").read_text())
    request["pairs"][0]["statistical_unit_id"] = "forged-unit"
    forged_request_id = write_forged_object(
        learn_root / "evidence", "codegraff-learn/evidence/v1", request,
    )
    forged_units["candidates"][0]["primary"]["request_evidence_id"] = forged_request_id
    forged_units_run_id = write_forged_object(
        learn_root / "runs", "codegraff-learn/run/v1", forged_units,
    )
    rejected_units = invoke(
        graff, workspace, env, "promote", forged_units_run_id, succeeds=False,
    )
    assert "PairMismatch" in rejected_units.stderr
    assert status(graff, workspace, env)["generation"] == 0

    # Raw regression counts are derived evidence, not trusted run metadata.
    # Omitting a real regression or inventing one must mismatch recomputation.
    forged_regressions = copy.deepcopy(record)
    forged_regressions["candidates"][0]["primary"]["correctness_regressions"] = 1
    forged_regressions_run_id = write_forged_object(
        learn_root / "runs", "codegraff-learn/run/v1", forged_regressions,
    )
    rejected_regressions = invoke(
        graff, workspace, env, "promote", forged_regressions_run_id, succeeds=False,
    )
    assert "ComparisonMismatch" in rejected_regressions.stderr
    assert status(graff, workspace, env)["generation"] == 0

    # The untampered v3 evidence remains fully verifiable and promotable.
    invoke(graff, workspace, env, "promote", run_id)
    assert status(graff, workspace, env)["generation"] == 1
    assert json.loads(invoke(graff, workspace, env, "verify").stdout)["integrity"] == "ok"

    # A suite that meets minimum_pairs but cannot possibly clear corrected
    # significance is rejected before model calls or store initialization.
    ineligible_workspace = root / "workspace-ineligible"
    ineligible_barrier = root / "barrier-ineligible"
    ineligible_workspace.mkdir(mode=0o700)
    ineligible_barrier.mkdir(mode=0o700)
    ineligible_config = copy.deepcopy(config)
    ineligible_config["gate"]["alpha_ppm"] = 1_000
    ineligible_config_path = root / "config-ineligible.json"
    write_private(ineligible_config_path, json_bytes(ineligible_config))
    ineligible_env = {**env, "TOURNAMENT_BARRIER": str(ineligible_barrier)}
    underpowered = invoke(
        graff, ineligible_workspace, ineligible_env, "init",
        "--parent", str(parent.resolve()), "--config", str(ineligible_config_path.resolve()),
        succeeds=False,
    )
    assert "InsufficientSignificancePower" in underpowered.stderr
    assert not ineligible_workspace.joinpath(".graff", "learn").exists()
    assert not (ineligible_barrier / "holdout-once").exists()

    # Different bytes are not enough to make a holdout fresh. Reusing a
    # primary statistical unit is rejected before store creation or adapters.
    overlap_workspace = root / "workspace-overlap"
    overlap_workspace.mkdir(mode=0o700)
    overlap_holdout = tools / "overlap-holdout.json"
    write_private(overlap_holdout, json_bytes({
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "tournament-overlap-holdout",
        "cases": [
            {"id": "holdout-copy", "statistical_unit_id": "primary-0"},
            *[{"id": f"fresh-{index}"} for index in range(7)],
        ],
    }))
    overlap_config = copy.deepcopy(config)
    overlap_config["holdout_suite"] = {
        "path": str(overlap_holdout.resolve()),
        "sha256": raw_sha256(overlap_holdout),
    }
    overlap_config_path = root / "config-overlap.json"
    write_private(overlap_config_path, json_bytes(overlap_config))
    overlapping = invoke(
        graff, overlap_workspace, env, "init", "--parent", str(parent.resolve()),
        "--config", str(overlap_config_path.resolve()), succeeds=False,
    )
    assert "HoldoutStatisticalUnitOverlap" in overlapping.stderr
    assert not overlap_workspace.joinpath(".graff", "learn").exists()

    # The run-time override is checked too: eight units can clear alpha=.01
    # for one arm, but not after correcting for four requested arms.
    override_workspace = root / "workspace-power-override"
    override_barrier = root / "barrier-power-override"
    override_workspace.mkdir(mode=0o700)
    override_barrier.mkdir(mode=0o700)
    override_config = copy.deepcopy(config)
    override_config["gate"]["alpha_ppm"] = 10_000
    override_config["gate"]["default_candidates"] = 1
    override_config_path = root / "config-power-override.json"
    write_private(override_config_path, json_bytes(override_config))
    override_env = {**env, "TOURNAMENT_BARRIER": str(override_barrier)}
    invoke(
        graff, override_workspace, override_env, "init",
        "--parent", str(parent.resolve()), "--config", str(override_config_path.resolve()),
    )
    impossible_override = invoke(
        graff, override_workspace, override_env, "run", "--candidates", "4",
        succeeds=False,
    )
    assert "InsufficientSignificancePower" in impossible_override.stderr
    assert not list(override_barrier.glob("mutation-*"))

    # A failure after holdout reservation leaves a verified, resumable trial.
    # New runs cannot overwrite it, forged state fails closed, and resuming the
    # original state must not repeat mutations, baseline, or primary arms.
    resume_workspace = root / "workspace-resume"
    resume_barrier = root / "barrier-resume"
    resume_workspace.mkdir(mode=0o700)
    resume_barrier.mkdir(mode=0o700)
    resume_env = {**env, "TOURNAMENT_BARRIER": str(resume_barrier)}
    invoke(
        graff, resume_workspace, resume_env, "init",
        "--parent", str(parent.resolve()), "--config", str(config_path.resolve()),
    )
    primary_fail_marker = resume_barrier / "fail-primary-1"
    primary_fail_marker.write_text("fail both bounded primary attempts")
    fail_marker = resume_barrier / "fail-holdout"
    fail_marker.write_text("fail both bounded holdout attempts")
    interrupted = invoke(
        graff, resume_workspace, resume_env, "run", "--candidates", "4",
        succeeds=False,
    )
    assert "ProcessFailed" in interrupted.stderr
    pending_path = resume_workspace / ".graff" / "learn" / "refs" / "pending.json"
    assert pending_path.is_file()
    pending_bytes = pending_path.read_bytes()
    pending_record = json.loads(pending_bytes)
    pending_status = status(graff, resume_workspace, resume_env)
    assert pending_status["pending_trial_id"] == pending_record["trial_id"]
    assert pending_status["pending_primary_arms"] == 3
    assert pending_status["pending_holdout_arms"] == 0
    assert pending_status["pending_verified"] is False
    verified_pending = json.loads(invoke(graff, resume_workspace, resume_env, "verify").stdout)
    assert verified_pending["pending_verified"] is True
    assert len(list(resume_barrier.glob("mutation-*"))) == 4
    assert len(list(resume_barrier.glob("primary-done-*"))) == 3
    assert (resume_barrier / "baseline-once").read_text() == "parent"
    assert not (resume_barrier / "holdout-once").exists()

    refused = invoke(
        graff, resume_workspace, resume_env, "run", "--candidates", "4",
        succeeds=False,
    )
    assert "PendingRunExists" in refused.stderr
    assert "--resume" in refused.stdout

    forged_pending = json.loads(pending_bytes)
    forged_pending["trial_id"] = "0" * 64
    write_private(pending_path, json_bytes(forged_pending))
    forged_resume = invoke(
        graff, resume_workspace, resume_env, "run", "--resume", "--candidates", "4",
        succeeds=False,
    )
    assert "TrialMismatch" in forged_resume.stderr
    forged_verify = invoke(graff, resume_workspace, resume_env, "verify", succeeds=False)
    assert "TrialMismatch" in forged_verify.stderr
    write_private(pending_path, pending_bytes)

    primary_fail_marker.unlink()
    holdout_interrupted = invoke(
        graff, resume_workspace, resume_env, "run", "--resume", "--candidates", "4",
        succeeds=False,
    )
    assert "ProcessFailed" in holdout_interrupted.stderr
    holdout_pending_status = status(graff, resume_workspace, resume_env)
    assert holdout_pending_status["pending_primary_arms"] == 4
    assert holdout_pending_status["pending_holdout_arms"] == 0
    assert (resume_barrier / "holdout-once").read_text() == "2"

    fail_marker.unlink()
    resumed_output = invoke(
        graff, resume_workspace, resume_env, "run", "--resume", "--candidates", "4",
    ).stdout
    resumed_id = run_id_from(resumed_output)
    assert "resuming checkpointed trial" in resumed_output
    assert not pending_path.exists()
    resumed_status = status(graff, resume_workspace, resume_env)
    assert resumed_status["pending_trial_id"] is None
    assert resumed_status["pending_primary_arms"] == 0
    assert resumed_status["pending_holdout_arms"] == 0
    assert resumed_status["pending_verified"] is True
    assert len(list(resume_barrier.glob("mutation-*"))) == 4
    assert len(list(resume_barrier.glob("primary-done-*"))) == 4
    assert (resume_barrier / "baseline-once").read_text() == "parent"
    assert (resume_barrier / "holdout-once").read_text() == "2"
    assert [
        (resume_barrier / f"primary-attempts-{index}").read_text()
        for index in range(4)
    ] == ["2", "3", "1", "1"]
    assert (resume_barrier / "holdout-attempts").read_text() == "3"
    resumed_record = json.loads(
        resume_workspace.joinpath(
            ".graff", "learn", "runs", f"{resumed_id}.json",
        ).read_text()
    )
    assert sum(item["holdout"] is not None for item in resumed_record["candidates"]) == 1

    # A persistent mutator failure gets exactly one retry. It fails before the
    # baseline/primary barrier and cannot leave a misleading resumable record.
    mutation_failure_workspace = root / "workspace-mutation-failure"
    mutation_failure_barrier = root / "barrier-mutation-failure"
    mutation_failure_workspace.mkdir(mode=0o700)
    mutation_failure_barrier.mkdir(mode=0o700)
    mutation_failure_env = {**env, "TOURNAMENT_BARRIER": str(mutation_failure_barrier)}
    invoke(
        graff, mutation_failure_workspace, mutation_failure_env, "init",
        "--parent", str(parent.resolve()), "--config", str(config_path.resolve()),
    )
    (mutation_failure_barrier / "fail-mutator-1").write_text("fail both bounded attempts")
    failed_mutation = invoke(
        graff, mutation_failure_workspace, mutation_failure_env,
        "run", "--candidates", "4", succeeds=False,
    )
    assert "IncompleteCandidateSet" in failed_mutation.stderr
    assert "private diagnostics hidden" in failed_mutation.stderr
    assert "PRIVATE_ADAPTER_CANARY_DO_NOT_EXPOSE" not in failed_mutation.stderr
    assert mutator["program"] not in failed_mutation.stderr
    assert Path(mutator["program"]).name not in failed_mutation.stderr
    assert (mutation_failure_barrier / "mutator-attempts-1").read_text() == "2"
    assert not (mutation_failure_barrier / "baseline-once").exists()
    assert status(graff, mutation_failure_workspace, mutation_failure_env)["pending_trial_id"] is None

    detailed_failure = invoke(
        graff, mutation_failure_workspace, mutation_failure_env,
        "run", "--candidates", "4", "--show-adapter-stderr", succeeds=False,
    )
    assert "PRIVATE_ADAPTER_CANARY_DO_NOT_EXPOSE" in detailed_failure.stderr
    assert Path(mutator["program"]).name in detailed_failure.stderr


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
