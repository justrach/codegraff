#!/usr/bin/env python3
"""Loopback E2E for local learning plus one explicit captured submission."""

from __future__ import annotations

import argparse
import copy
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
from typing import Any

from learning_receipt_assertions import assert_learning_records


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


# Real bodies of the fixture mutator/evaluator programs, kept as plain
# (non-f, raw) strings: they carry their own `"\n"` escapes verbatim into
# the generated file, and none of their braces or quotes need doubling up
# the way an f-string would demand.
MUTATOR_BODY = r'''import hashlib, json, os, pathlib, sys
assert pathlib.Path(sys.argv[0]).resolve() != pathlib.Path(os.environ["FIXTURE_MUTATOR_SOURCE"]).resolve()
operation, request_path, response_path = sys.argv[1:4]
assert operation == "mutate"
request = json.loads(pathlib.Path(request_path).read_text())
parent = pathlib.Path(request["parent"]["path"]).read_text()
child = parent.rstrip() + "\n\nLearned fixture policy.\n"
child_bytes = child.encode()
pathlib.Path(request["child_path"]).write_bytes(child_bytes)
response = {
    "schema": "codegraff.learn.mutation.response.v1",
    "trial_id": request["trial_id"],
    "candidate_index": request["candidate_index"],
    "parent_id": request["parent"]["id"],
    "child_path": request["child_path"],
    "child_sha256": hashlib.sha256(child_bytes).hexdigest(),
    "description": "deterministic fixture mutation",
}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''

EVALUATOR_BODY = r'''import hashlib, json, os, pathlib, sys
assert pathlib.Path(sys.argv[0]).resolve() != pathlib.Path(os.environ["FIXTURE_EVALUATOR_SOURCE"]).resolve()
operation, request_path, response_path = sys.argv[1:4]
request = json.loads(pathlib.Path(request_path).read_text())
assert request["suite_path"] == "suite.json"
suite_bytes = pathlib.Path(request["suite_path"]).read_bytes()
assert hashlib.sha256(suite_bytes).hexdigest() == request["suite_sha256"]
if operation == "baseline":
    pairs = [{
        "case_id": pair["case_id"], "seed": pair["seed"],
        "pass": False, "score_ppm": 0, "cost_micros": 100,
    } for pair in request["pairs"]]
    response = {
        "schema": "codegraff.learn.primary-baseline.response.v1",
        "trial_id": request["trial_id"], "cohort_id": request["cohort_id"],
        "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent"]["id"], "pairs": pairs,
    }
elif operation == "evaluate_primary":
    baseline = json.loads(pathlib.Path(request["baseline"]["path"]).read_text())
    pairs = [{
        "case_id": parent["case_id"], "seed": parent["seed"],
        "parent_pass": parent["pass"], "child_pass": True,
        "parent_score_ppm": parent["score_ppm"], "child_score_ppm": 1000000,
        "parent_cost_micros": parent["cost_micros"], "child_cost_micros": 90,
    } for parent in baseline["pairs"]]
    response = {
        "schema": "codegraff.learn.primary-evaluation.response.v1",
        "trial_id": request["trial_id"], "candidate_index": request["candidate_index"],
        "cohort_id": request["cohort_id"], "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent_id"], "child_id": request["child"]["id"],
        "pairs": pairs,
    }
elif operation == "evaluate":
    pairs = [{
        "case_id": pair["case_id"], "seed": pair["seed"],
        "parent_pass": False, "child_pass": True,
        "parent_score_ppm": 0, "child_score_ppm": 1000000,
        "parent_cost_micros": 100, "child_cost_micros": 90,
    } for pair in request["pairs"]]
    response = {
        "schema": "codegraff.learn.evaluation.response.v1",
        "trial_id": request["trial_id"], "candidate_index": request["candidate_index"],
        "cohort_id": request["cohort_id"], "suite_sha256": request["suite_sha256"],
        "parent_id": request["parent"]["id"], "child_id": request["child"]["id"],
        "pairs": pairs,
    }
else:
    raise AssertionError(f"unexpected operation {operation}")
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''

MUTATOR_IDENTICAL_BODY = r'''import hashlib, json, pathlib, sys
operation, request_path, response_path = sys.argv[1:4]
assert operation == "mutate"
request = json.loads(pathlib.Path(request_path).read_text())
parent = pathlib.Path(request["parent"]["path"]).read_text()
child = parent if request["candidate_index"] < 2 else parent.rstrip() + "\n\nLearned fixture policy.\n"
child_bytes = child.encode()
pathlib.Path(request["child_path"]).write_bytes(child_bytes)
response = {
    "schema": "codegraff.learn.mutation.response.v1",
    "trial_id": request["trial_id"],
    "candidate_index": request["candidate_index"],
    "parent_id": request["parent"]["id"],
    "child_path": request["child_path"],
    "child_sha256": hashlib.sha256(child_bytes).hexdigest(),
    "description": "parent-identical below index 2",
}
pathlib.Path(response_path).write_text(json.dumps(response, separators=(",", ":")) + "\n")
'''


def write_posix_shebang(path: Path, python: Path, body: str, mode: int = 0o700) -> None:
    """POSIX-only: a directly-executed `#!` script. Not viable on Windows —
    CreateProcess has no notion of a shebang line, so a `.py` written this
    way just fails to launch there."""
    write_private(path, (f"#!{python}\n" + body).encode(), mode)


def write_interpreter_shim(tools: Path, name: str, python: Path, body: str) -> tuple[dict[str, Any], Path]:
    """Write the real script as inert data (never executed directly) plus a
    tiny launcher that execs the pinned CPython interpreter with it: a
    `.cmd` on Windows, since CreateProcess cannot run a `.py`'s shebang line
    there, and a `.sh` everywhere else so the very same launcher shape is
    exercised cross-platform.

    The launcher is the config Program's `program` (what invoke() snapshots
    and executes); the real script travels back as one of the Program's
    pinned `inputs`, and its original path is echoed into `args` so
    invoke()'s substitution rewrites it to the snapshot path before exec.
    Returns the Program dict plus the script's own pre-snapshot path (the
    latter for FIXTURE_*_SOURCE env wiring: an identity check the fixture
    programs use to prove they are executing off the scratch snapshot, not
    the original pinned file).
    """
    script = tools / f"{name}-real.py"
    write_private(script, body.encode(), 0o600)
    if sys.platform == "win32":
        launcher = tools / f"{name}.cmd"
        launcher_source = f'@echo off\r\n"{python}" %*\r\n'
    else:
        launcher = tools / f"{name}.sh"
        launcher_source = f'#!/bin/sh\nexec "{python}" "$@"\n'
    write_private(launcher, launcher_source.encode(), 0o700)
    program = {
        "program": str(launcher.resolve()),
        "sha256": raw_sha256(launcher),
        "args": [str(script.resolve())],
        "inputs": [{"path": str(script.resolve()), "sha256": raw_sha256(script)}],
    }
    return program, script


def invoke(graff: Path, workspace: Path, env: dict[str, str], *args: str, succeeds: bool = True, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    privacy_args = ["--learning-privacy", "aggregate"] if (args and (args[0] == "submit" or "--submit" in args)) else []
    result = subprocess.run(
        [str(graff), *privacy_args, "learn", *args],
        cwd=workspace,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
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


class GradeCapture(BaseHTTPRequestHandler):
    payloads: list[dict[str, Any]] = []
    deletions: list[tuple[str, str | None]] = []

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        assert self.path == "/v1/logs"
        length = int(self.headers["content-length"])
        self.payloads.append(json.loads(self.rfile.read(length)))
        self.send_response(202)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"queued":true}')

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.deletions.append((self.path, self.headers.get("x-learning-delete-token")))
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format: str, *_args: Any) -> None:
        pass


def verify_grade_submit(graff: Path, workspace: Path, env: dict[str, str], root: Path, run_id: str) -> None:
    """The explicit publish path sends signed aggregates and no genome text."""
    key = b"fixture-score-key"
    key_path = root / ".simple-harness" / "score.key"
    key_path.parent.mkdir(mode=0o700)
    write_private(key_path, key + b"\n")
    GradeCapture.payloads = []
    GradeCapture.deletions = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), GradeCapture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    submit_env = env.copy()
    submit_env.pop("GRAFF_NO_TELEMETRY", None)
    submit_env["HOME"] = str(root)
    submit_env["GRAFF_OTEL_ENDPOINT"] = f"http://127.0.0.1:{server.server_port}"
    submit_env.pop("GRAFF_SCORE_KEY_FILE", None)
    try:
        # Aggregate is the default ceiling, so Local is now the *selected*
        # state that must still fail before any network egress.
        local = subprocess.run(
            [str(graff), "learn", "submit", run_id],
            cwd=workspace,
            env={**submit_env, "GRAFF_LEARNING_PRIVACY": "local"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        assert local.returncode != 0 and "LearningPrivacyLocal" in local.stderr
        assert not GradeCapture.payloads, "local privacy must fail before network egress"
        # A garbled ceiling must fail closed to Local rather than fall back to
        # the aggregate default.
        garbled = subprocess.run(
            [str(graff), "learn", "submit", run_id],
            cwd=workspace,
            env={**submit_env, "GRAFF_LEARNING_PRIVACY": "AGGREGATE"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        assert garbled.returncode != 0 and "LearningPrivacyLocal" in garbled.stderr
        assert not GradeCapture.payloads, "a garbled privacy value must not enable egress"
        fleet_off_env = {**submit_env, "GRAFF_FLEET": "off"}
        disabled = invoke(graff, workspace, fleet_off_env, "submit", run_id, succeeds=False)
        assert "TelemetryDisabled" in disabled.stderr
        assert not GradeCapture.payloads, "fleet master-off must block learning egress"
        # No flag and no environment value: the default ceiling is Aggregate,
        # which is the only reason an automatic trial can contribute anything.
        default_submit = subprocess.run(
            [str(graff), "learn", "submit", run_id],
            cwd=workspace,
            env=submit_env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
        assert default_submit.returncode == 0, default_submit.stderr
        output = default_submit.stdout
        assert "submitted 2 signed aggregate grade(s)" in output
        delete_env = {**submit_env, "GRAFF_NO_TELEMETRY": "1", "GRAFF_FLEET": "off"}
        deleted = invoke(graff, workspace, delete_env, "delete-remote", run_id).stdout
        assert "local evidence was not changed" in deleted
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert len(GradeCapture.payloads) == 1
    run = json.loads((workspace / ".graff" / "learn" / "runs" / f"{run_id}.json").read_text())
    delete_message = f"codegraff.learn.delete.v1\n{run_id}\n{run['nonce']}".encode()
    expected_delete_token = hmac.new(key, delete_message, hashlib.sha256).hexdigest()
    assert GradeCapture.deletions == [(f"/v1/learning/{run_id}", expected_delete_token)]
    payload = GradeCapture.payloads[0]
    encoded = json.dumps(payload, separators=(",", ":"))
    assert "prompt_text" not in encoded and "Learned fixture policy" not in encoded
    resource = payload["resourceLogs"][0]
    resource_attrs = {item["key"]: next(iter(item["value"].values())) for item in resource["resource"]["attributes"]}
    assert resource_attrs == {"client.name": "harness-learn"}
    assert not (root / ".simple-harness-install-id").exists()
    records = resource["scopeLogs"][0]["logRecords"]
    assert len(records) == 2
    assert_learning_records(records, run_id, key, 1, expected_delete_token)


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

    python = Path(sys.executable).resolve()

    # The mutator keeps the plain shebang model unchanged on POSIX; on
    # Windows every tool must go through write_interpreter_shim since
    # CreateProcess cannot execute a .py shebang script directly.
    if sys.platform == "win32":
        mutator_program, mutator_source = write_interpreter_shim(tools, "mutator", python, MUTATOR_BODY)
    else:
        mutator_source = tools / "mutator.py"
        write_posix_shebang(mutator_source, python, MUTATOR_BODY)
        mutator_program = {"program": str(mutator_source.resolve()), "sha256": raw_sha256(mutator_source)}
    mutator_program["pass_env"] = ["FIXTURE_MUTATOR_SOURCE"]

    # The evaluator always travels as interpreter + pinned input, on POSIX
    # too, even though POSIX could run it as a plain shebang script like the
    # mutator above. This is deliberate: it is the only way this fixture,
    # run on this (non-Windows) machine, can actually exercise invoke()'s
    # inputs+args-substitution path end to end and prove the machinery the
    # Windows .cmd shim depends on really works. windows-latest CI remains
    # the real arbiter for the Windows launcher itself.
    evaluator_program, evaluator_source = write_interpreter_shim(tools, "evaluator", python, EVALUATOR_BODY)
    evaluator_program["pass_env"] = ["FIXTURE_EVALUATOR_SOURCE"]

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
        "mutator": mutator_program,
        "evaluator": evaluator_program,
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
            "FIXTURE_MUTATOR_SOURCE": str(mutator_source.resolve()),
            "FIXTURE_EVALUATOR_SOURCE": str(evaluator_source.resolve()),
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
    verify_grade_submit(graff, workspace, env, root, manual_run)

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

    # A second default-target rollback would move FORWARD (previous_genome_id
    # of a rollback transaction names the genome just rolled away from) and
    # silently reinstate it; it must demand an explicit --to instead.
    invoke(graff, workspace, env, "rollback", succeeds=False)
    assert status(graff, workspace, env)["generation"] == 2

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

    # This workspace already exposed its configured hidden suite. A later run
    # must fail before reusing it, even for an automatic promotion request.
    consumed = invoke(graff, workspace, env, "run", "--auto", succeeds=False)
    assert "HoldoutConsumed" in consumed.stderr
    assert status(graff, workspace, env)["generation"] == 2

    # Automatic promotion remains covered with a fresh, independently pinned
    # hidden suite in a separate learning store.
    automatic_workspace = root / "workspace-auto"
    automatic_workspace.mkdir(mode=0o700)
    automatic_holdout = tools / "holdout-suite-auto.json"
    automatic_manifest = copy.deepcopy(holdout_manifest)
    automatic_manifest["suite_id"] = "fixture-holdout-auto"
    write_private(automatic_holdout, json_bytes(automatic_manifest))
    automatic_config = copy.deepcopy(config)
    automatic_config["holdout_suite"] = {
        "path": str(automatic_holdout.resolve()),
        "sha256": raw_sha256(automatic_holdout),
    }
    automatic_config_path = root / "config-auto.json"
    write_private(automatic_config_path, json_bytes(automatic_config))
    invoke(
        graff, automatic_workspace, env, "init",
        "--parent", str(parent.resolve()), "--config", str(automatic_config_path.resolve()),
    )
    automatic_output = invoke(graff, automatic_workspace, env, "run", "--auto").stdout
    assert run_id_from(automatic_output)
    automatic = status(graff, automatic_workspace, env)
    assert automatic["generation"] == 1
    assert automatic["active_genome_id"] != initial_genome
    verified = invoke(graff, automatic_workspace, env, "verify")
    assert json.loads(verified.stdout)["integrity"] == "ok"

    exercise_identical_parent(graff, root, evaluator_program, holdout_suite, evaluation_suite, parent, env)
    exercise_init_recovery(graff, root, config_path, parent, env)


def exercise_identical_parent(
    graff: Path,
    root: Path,
    evaluator_program: dict[str, Any],
    holdout_suite: Path,
    evaluation_suite: Path,
    parent: Path,
    env: dict[str, str],
) -> None:
    """Regression: a run whose first candidates reproduce the parent byte for
    byte must stay verifiable and promotable. verifyRun used to let
    duplicate_candidate overwrite identical_parent (diverging from the
    writer), which made such a run permanently unpromotable."""
    workspace = root / "workspace-identical"
    workspace.mkdir(mode=0o700)
    tools = root / "tools"
    python = Path(sys.executable).resolve()

    if sys.platform == "win32":
        mutator_program, _ = write_interpreter_shim(tools, "mutator-identical", python, MUTATOR_IDENTICAL_BODY)
    else:
        mutator_source = tools / "mutator-identical.py"
        write_posix_shebang(mutator_source, python, MUTATOR_IDENTICAL_BODY)
        mutator_program = {"program": str(mutator_source.resolve()), "sha256": raw_sha256(mutator_source)}

    config_path = root / "config-identical.json"
    config = {
        "schema": "codegraff.learn.config.v1",
        "agent_name": "fixture-identical",
        "agent_description": "parent-identical candidate regression",
        "mutation_instruction": "reproduce the parent for the first two candidates",
        "mutator": mutator_program,
        "evaluator": evaluator_program,
        "evaluation_suite": {"path": str(evaluation_suite.resolve()), "sha256": raw_sha256(evaluation_suite)},
        "holdout_suite": {"path": str(holdout_suite.resolve()), "sha256": raw_sha256(holdout_suite)},
        "gate": {
            "alpha_ppm": 50000,
            "minimum_delta_ppm": 100000,
            "minimum_pairs": 6,
            "default_candidates": 3,
            "default_repetitions": 3,
        },
        "auto": {"enabled": False},
        "cohort": {
            "provider": "fixture",
            "model": "fixture",
            "task_family": "local-e2e",
            "adapter_version": "v1",
            "verifier_version": "v1",
        },
    }
    write_private(config_path, json_bytes(config))

    invoke(graff, workspace, env, "init", "--parent", str(parent.resolve()), "--config", str(config_path.resolve()))
    run_output = invoke(graff, workspace, env, "run").stdout
    run_id = run_id_from(run_output)
    record = json.loads((workspace / ".graff" / "learn" / "runs" / f"{run_id}.json").read_text())
    reasons = [candidate["reason"] for candidate in record["candidates"]]
    assert reasons[0] == "identical_parent" and reasons[1] == "identical_parent", reasons
    assert record["candidates"][2]["eligible"], reasons
    invoke(graff, workspace, env, "promote", run_id)
    assert status(graff, workspace, env)["generation"] == 1


def exercise_init_recovery(graff: Path, root: Path, config_path: Path, parent: Path, env: dict[str, str]) -> None:
    """Regression: a rejected parent must not create the store tree, and the
    residue of an interrupted init must be re-initializable rather than
    wedging every later init with AlreadyInitialized."""
    workspace = root / "workspace-wedge"
    workspace.mkdir(mode=0o700)
    bad_parent = root / "bad-parent.md"
    write_private(bad_parent, b"   \n\t\n")
    invoke(graff, workspace, env, "init", "--parent", str(bad_parent.resolve()), "--config", str(config_path.resolve()), succeeds=False)
    assert not (workspace / ".graff" / "learn").exists(), "rejected parent must not create the store"

    # Crash residue: a partial tree without refs/active.json must be adopted.
    (workspace / ".graff").mkdir(mode=0o700)
    (workspace / ".graff" / "learn").mkdir(mode=0o700)
    (workspace / ".graff" / "learn" / "configs").mkdir(mode=0o700)
    invoke(graff, workspace, env, "init", "--parent", str(parent.resolve()), "--config", str(config_path.resolve()))
    assert status(graff, workspace, env)["generation"] == 0


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
