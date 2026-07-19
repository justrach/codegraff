#!/usr/bin/env python3
"""Local-only end-to-end regression test for `graff learn`.

Build first, then run:
    python3 tests/learn_e2e.py --graff zig-out/bin/graff

The fixture uses deterministic local mutator/evaluator programs and disables
telemetry. It never contacts a network service.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Any


def raw_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def addressed_id(domain: str, data: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(domain.encode("utf-8"))
    digest.update(b"\0")
    digest.update(struct.pack(">Q", len(data)))
    digest.update(data)
    return digest.hexdigest()


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


def write_private(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.write_bytes(data)
    path.chmod(mode)


def invoke(graff: Path, workspace: Path, env: dict[str, str], *args: str, succeeds: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(graff), "learn", *args],
        cwd=workspace,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=False,
    )
    if succeeds and result.returncode != 0:
        raise AssertionError(f"command failed: {' '.join(args)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    if not succeeds and result.returncode == 0:
        raise AssertionError(f"command unexpectedly succeeded: {' '.join(args)}\n{result.stdout}")
    return result


def run_id_from(output: str) -> str:
    match = re.search(r"^run ([0-9a-f]{64})$", output, re.MULTILINE)
    if match is None:
        raise AssertionError(f"missing run id in output:\n{output}")
    return match.group(1)


def status(graff: Path, workspace: Path, env: dict[str, str]) -> dict[str, Any]:
    return json.loads(invoke(graff, workspace, env, "status").stdout)


def write_forged_object(directory: Path, domain: str, value: Any) -> str:
    data = json_bytes(value)
    object_id = addressed_id(domain, data)
    write_private(directory / f"{object_id}.json", data)
    return object_id


def exercise(graff: Path, root: Path) -> None:
    workspace = root / "workspace"
    workspace.mkdir(mode=0o700)
    tools = root / "tools"
    tools.mkdir(mode=0o700)

    mutator = tools / "mutator.py"
    evaluator = tools / "evaluator.py"
    python = Path(sys.executable).resolve()
    mutator_source = f"""#!{python}
import hashlib, json, os, pathlib, sys
assert pathlib.Path(sys.argv[0]).resolve() != pathlib.Path(os.environ[\"FIXTURE_MUTATOR_SOURCE\"]).resolve()
operation, request_path, response_path = sys.argv[1:4]
assert operation == \"mutate\"
request = json.loads(pathlib.Path(request_path).read_text())
parent = pathlib.Path(request[\"parent\"][\"path\"]).read_text()
child = parent.rstrip() + \"\\n\\nLearned fixture policy.\\n\"
child_bytes = child.encode()
pathlib.Path(request[\"child_path\"]).write_bytes(child_bytes)
response = {{
    \"schema\": \"codegraff.learn.mutation.response.v1\",
    \"trial_id\": request[\"trial_id\"],
    \"candidate_index\": request[\"candidate_index\"],
    \"parent_id\": request[\"parent\"][\"id\"],
    \"child_path\": request[\"child_path\"],
    \"child_sha256\": hashlib.sha256(child_bytes).hexdigest(),
    \"description\": \"deterministic fixture mutation\",
}}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(\",\", \":\")) + \"\\n\")
"""
    evaluator_source = f"""#!{python}
import hashlib, json, os, pathlib, sys
assert pathlib.Path(sys.argv[0]).resolve() != pathlib.Path(os.environ[\"FIXTURE_EVALUATOR_SOURCE\"]).resolve()
operation, request_path, response_path = sys.argv[1:4]
assert operation == \"evaluate\"
request = json.loads(pathlib.Path(request_path).read_text())
assert request[\"suite_path\"] == \"suite.json\"
suite_bytes = pathlib.Path(request[\"suite_path\"]).read_bytes()
assert hashlib.sha256(suite_bytes).hexdigest() == request[\"suite_sha256\"]
pairs = []
for pair in request[\"pairs\"]:
    pairs.append({{
        \"case_id\": pair[\"case_id\"],
        \"seed\": pair[\"seed\"],
        \"parent_pass\": False,
        \"child_pass\": True,
        \"parent_score_ppm\": 0,
        \"child_score_ppm\": 1000000,
        \"parent_cost_micros\": 100,
        \"child_cost_micros\": 90,
    }})
response = {{
    \"schema\": \"codegraff.learn.evaluation.response.v1\",
    \"trial_id\": request[\"trial_id\"],
    \"candidate_index\": request[\"candidate_index\"],
    \"cohort_id\": request[\"cohort_id\"],
    \"suite_sha256\": request[\"suite_sha256\"],
    \"parent_id\": request[\"parent\"][\"id\"],
    \"child_id\": request[\"child\"][\"id\"],
    \"pairs\": pairs,
}}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(\",\", \":\")) + \"\\n\")
"""
    write_private(mutator, mutator_source.encode(), 0o700)
    write_private(evaluator, evaluator_source.encode(), 0o700)

    evaluation_suite = tools / "evaluation-suite.json"
    holdout_suite = tools / "holdout-suite.json"
    evaluation_manifest = {
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "fixture-primary",
        "cases": [{"id": f"primary-{index}"} for index in range(6)],
    }
    holdout_manifest = {
        "schema": "codegraff.learn.suite.v1",
        "suite_id": "fixture-holdout",
        "cases": [{"id": f"holdout-{index}"} for index in range(6)],
    }
    write_private(evaluation_suite, json_bytes(evaluation_manifest))
    write_private(holdout_suite, json_bytes(holdout_manifest))

    parent = root / "parent.md"
    write_private(parent, b"Initial fixture policy.\n")
    config_path = root / "config.json"
    config = {
        "schema": "codegraff.learn.config.v1",
        "agent_name": "fixture-agent",
        "agent_description": "local deterministic learning fixture",
        "mutation_instruction": "append the fixture policy sentence",
        "mutator": {
            "program": str(mutator.resolve()),
            "sha256": raw_sha256(mutator),
            "pass_env": ["FIXTURE_MUTATOR_SOURCE"],
        },
        "evaluator": {
            "program": str(evaluator.resolve()),
            "sha256": raw_sha256(evaluator),
            "pass_env": ["FIXTURE_EVALUATOR_SOURCE"],
        },
        "evaluation_suite": {"path": str(evaluation_suite.resolve()), "sha256": raw_sha256(evaluation_suite)},
        "holdout_suite": {"path": str(holdout_suite.resolve()), "sha256": raw_sha256(holdout_suite)},
        "gate": {
            "alpha_ppm": 50000,
            "minimum_delta_ppm": 100000,
            "minimum_pairs": 6,
            "default_candidates": 1,
            "default_repetitions": 3,
        },
        "auto": {"enabled": True},
        "cohort": {
            "provider": "fixture",
            "model": "fixture",
            "task_family": "local-e2e",
            "adapter_version": "v1",
            "verifier_version": "v1",
        },
    }
    write_private(config_path, json_bytes(config))

    env = os.environ.copy()
    env.update(
        {
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_BEHAVIOR_TRACE": "0",
            "FIXTURE_MUTATOR_SOURCE": str(mutator.resolve()),
            "FIXTURE_EVALUATOR_SOURCE": str(evaluator.resolve()),
        }
    )

    invoke(graff, workspace, env, "init", "--parent", str(parent.resolve()), "--config", str(config_path.resolve()))
    initial = status(graff, workspace, env)
    assert initial["generation"] == 0
    initial_genome = initial["active_genome_id"]

    manual_output = invoke(graff, workspace, env, "run").stdout
    manual_run = run_id_from(manual_output)
    learn_root = workspace / ".graff" / "learn"
    run_path = learn_root / "runs" / f"{manual_run}.json"
    original_record = json.loads(run_path.read_text())

    # A forged mutation response that does not bind the selected child bytes
    # must not become promotable, even if all other run evidence is copied.
    bad_response_record = copy.deepcopy(original_record)
    mutation_response_id = bad_response_record["candidates"][0]["mutation"]["response_evidence_id"]
    mutation_response = json.loads((learn_root / "evidence" / f"{mutation_response_id}.json").read_text())
    mutation_response["child_sha256"] = "0" * 64
    bad_evidence_id = write_forged_object(learn_root / "evidence", "codegraff-learn/evidence/v1", mutation_response)
    bad_response_record["candidates"][0]["mutation"]["response_evidence_id"] = bad_evidence_id
    bad_response_run = write_forged_object(learn_root / "runs", "codegraff-learn/run/v1", bad_response_record)
    invoke(graff, workspace, env, "promote", bad_response_run, succeeds=False)
    assert status(graff, workspace, env)["generation"] == 0

    # Trial IDs are derived by the engine, not trusted from a run record.
    bad_trial_record = copy.deepcopy(original_record)
    bad_trial_record["trial_id"] = "0" * 64
    bad_trial_run = write_forged_object(learn_root / "runs", "codegraff-learn/run/v1", bad_trial_record)
    invoke(graff, workspace, env, "promote", bad_trial_run, succeeds=False)
    assert status(graff, workspace, env)["generation"] == 0

    invoke(graff, workspace, env, "promote", manual_run)
    promoted = status(graff, workspace, env)
    assert promoted["generation"] == 1
    assert promoted["active_genome_id"] != initial_genome

    invoke(graff, workspace, env, "rollback")
    rolled_back = status(graff, workspace, env)
    assert rolled_back["generation"] == 2
    assert rolled_back["active_genome_id"] == initial_genome

    # Returning to identical parent bytes does not make old evidence fresh: the
    # parent generation and transaction ID must also match.
    invoke(graff, workspace, env, "promote", manual_run, succeeds=False)
    assert status(graff, workspace, env)["generation"] == 2

    # Those fields are part of the trial derivation, not independently editable
    # labels. Rebinding an old content-addressed run to the rollback transaction
    # must invalidate its trial ID and all seeds derived from it.
    rebound_record = copy.deepcopy(original_record)
    rebound_record["parent_generation"] = rolled_back["generation"]
    rebound_record["parent_transaction_id"] = rolled_back["transaction_id"]
    rebound_run = write_forged_object(learn_root / "runs", "codegraff-learn/run/v1", rebound_record)
    invoke(graff, workspace, env, "promote", rebound_run, succeeds=False)
    assert status(graff, workspace, env)["generation"] == 2

    automatic_output = invoke(graff, workspace, env, "run", "--auto").stdout
    assert run_id_from(automatic_output)
    automatic = status(graff, workspace, env)
    assert automatic["generation"] == 3
    assert automatic["active_genome_id"] != initial_genome
    verified = invoke(graff, workspace, env, "verify")
    assert json.loads(verified.stdout)["integrity"] == "ok"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    parser.add_argument("--keep", action="store_true", help="preserve the temporary fixture directory")
    args = parser.parse_args()
    graff = args.graff.resolve()
    if not graff.is_file():
        parser.error(f"graff binary not found: {graff}")

    root = Path(tempfile.mkdtemp(prefix="codegraff-learn-e2e."))
    try:
        exercise(graff, root)
    except Exception:
        print(f"learning E2E failed; fixture preserved at {root}", file=sys.stderr)
        raise
    if args.keep:
        print(f"learning E2E passed; fixture preserved at {root}")
    else:
        shutil.rmtree(root)
        print("learning E2E passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
