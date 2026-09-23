#!/usr/bin/env python3
"""Offline CLI wiring test for the optional native learning formal gate.

The helper is deliberately a pinned fixture, not a TLC proof. This test checks
that native command boundaries invoke and reject its result as configured.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from learn_e2e import (
    EVALUATOR_BODY,
    MUTATOR_BODY,
    invoke,
    json_bytes,
    raw_sha256,
    run_id_from,
    status,
    write_interpreter_shim,
    write_private,
)


def setup(graff: Path, root: Path) -> tuple[Path, Path, dict[str, str], Path, Path, Path]:
    tools = root / "tools"
    tools.mkdir(mode=0o700)
    binary = Path("/bin/sh").resolve()
    binary_pin = {"path": str(binary), "sha256": raw_sha256(binary)}
    mutator_marker = root / "mutator-called"
    evaluator_fail = root / "evaluator-fail"
    mutator_body = MUTATOR_BODY.replace(
        "operation, request_path, response_path = sys.argv[1:4]",
        f"binary = pathlib.Path(sys.argv.pop(1))\nassert binary.is_file()\n"
        f"pathlib.Path({str(mutator_marker)!r}).write_text('called')\n"
        "operation, request_path, response_path = sys.argv[1:4]",
    )
    evaluator_body = EVALUATOR_BODY.replace(
        "operation, request_path, response_path = sys.argv[1:4]",
        f"binary = pathlib.Path(sys.argv.pop(1))\nassert binary.is_file()\n"
        f"if pathlib.Path({str(evaluator_fail)!r}).exists(): raise SystemExit(9)\n"
        "operation, request_path, response_path = sys.argv[1:4]",
    )
    python = Path(sys.executable).resolve()
    mutator, mutator_source = write_interpreter_shim(tools, "formal-mutator", python, mutator_body)
    evaluator, evaluator_source = write_interpreter_shim(tools, "formal-evaluator", python, evaluator_body)
    for program in (mutator, evaluator):
        program["args"].append(str(binary))
        program["inputs"].append(binary_pin)
    mutator["pass_env"] = ["FIXTURE_MUTATOR_SOURCE"]
    evaluator["pass_env"] = ["FIXTURE_EVALUATOR_SOURCE"]

    helper_control = root / "helper-control"
    helper_count = root / "helper-count"
    helper = tools / "formal-helper.py"
    helper_body = f'''import json, pathlib, sys
control = pathlib.Path({str(helper_control)!r})
count = pathlib.Path({str(helper_count)!r})
count.write_text(str(int(count.read_text()) + 1 if count.exists() else 1))
mode = control.read_text() if control.exists() else "good"
if mode == "fail": raise SystemExit(7)
print(json.dumps({{
    "schema": "codegraff.dgm.formal-check.v1", "ok": mode != "false",
    "candidate_prompt_sha256": sys.argv[-1],
    "formal_identity_sha256": "a" * 64,
    "checker_output_sha256": "b" * 64,
    "binary_sha256": {binary_pin['sha256']!r},
}}))
'''
    write_private(helper, helper_body.encode())
    formal_pin = tools / "formal-pin.json"
    write_private(formal_pin, json_bytes({"binary": binary_pin}))
    score_key = root / "score-key"
    write_private(score_key, b"fixture key\n")

    primary = tools / "primary.json"
    holdout = tools / "holdout.json"
    for path, suite_id in ((primary, "formal-primary"), (holdout, "formal-holdout")):
        write_private(path, json_bytes({
            "schema": "codegraff.learn.suite.v1", "suite_id": suite_id,
            "cases": [{"id": f"{suite_id}-{index}"} for index in range(6)],
        }))
    parent = root / "parent.md"
    write_private(parent, b"Initial fixture policy.\n")
    config = root / "config.json"
    write_private(config, json_bytes({
        "schema": "codegraff.learn.config.v1",
        "agent_name": "formal-fixture",
        "mutation_instruction": "append the fixture policy sentence",
        "mutator": mutator, "evaluator": evaluator,
        "formal_check": {
            "checker": {"program": str(python), "sha256": raw_sha256(python),
                        "args": [str(helper.resolve())],
                        "inputs": [{"path": str(helper.resolve()), "sha256": raw_sha256(helper)}]},
            "pin": {"path": str(formal_pin.resolve()), "sha256": raw_sha256(formal_pin)},
            "timeout_ms": 10000,
        },
        "evaluation_suite": {"path": str(primary.resolve()), "sha256": raw_sha256(primary)},
        "holdout_suite": {"path": str(holdout.resolve()), "sha256": raw_sha256(holdout)},
        "gate": {"alpha_ppm": 50000, "minimum_delta_ppm": 100000,
                 "minimum_pairs": 6, "default_candidates": 1, "default_repetitions": 3},
        "auto": {"enabled": True},
        "cohort": {"provider": "fixture", "model": "fixture", "task_family": "local-e2e",
                   "adapter_version": "v1", "verifier_version": "v1"},
    }))
    env = {**os.environ, "GRAFF_NO_TELEMETRY": "1", "GRAFF_LEARN_AUTO": "off",
           "GRAFF_SCORE_KEY_FILE": str(score_key.resolve()),
           "FIXTURE_MUTATOR_SOURCE": str(mutator_source.resolve()),
           "FIXTURE_EVALUATOR_SOURCE": str(evaluator_source.resolve())}
    workspace = root / "manual"
    workspace.mkdir(mode=0o700)
    invoke(graff, workspace, env, "init", "--parent", str(parent.resolve()),
           "--config", str(config.resolve()))
    return workspace, parent, env, helper_control, helper_count, evaluator_fail


def exercise(graff: Path, root: Path) -> None:
    workspace, parent, env, control, count, eval_fail = setup(graff, root)
    marker = root / "mutator-called"
    refused = invoke(graff, workspace, env, "run", "--submit", succeeds=False)
    assert "FormalReceiptUnsupported" in refused.stderr
    assert not marker.exists()

    control.write_text("fail")
    failed = invoke(graff, workspace, env, "run", succeeds=False)
    assert "FormalCheckFailed" in failed.stderr and not marker.exists()
    control.write_text("false")
    false = invoke(graff, workspace, env, "run", succeeds=False)
    assert "InvalidFormalCheckResult" in false.stderr and not marker.exists()
    control.unlink()

    eval_fail.touch()
    failed_eval = invoke(graff, workspace, env, "run", succeeds=False)
    assert "ProcessFailed" in failed_eval.stderr and marker.exists()
    pending_path = workspace / ".graff" / "learn" / "refs" / "pending.json"
    pending = json.loads(pending_path.read_text())
    assert pending["schema"] == "codegraff.learn.pending.v2"
    original_evidence = pending["formal_admission_evidence_id"]
    pending["formal_admission_evidence_id"] = "d" * 64
    write_private(pending_path, json_bytes(pending))
    rejected = invoke(graff, workspace, env, "run", "--resume", succeeds=False)
    assert "FileNotFound" in rejected.stderr
    pending["formal_admission_evidence_id"] = original_evidence
    write_private(pending_path, json_bytes(pending))
    eval_fail.unlink()
    manual_run = run_id_from(invoke(graff, workspace, env, "run", "--resume").stdout)
    run_path = workspace / ".graff" / "learn" / "runs" / f"{manual_run}.json"
    run = json.loads(run_path.read_text())
    assert run["schema"] == "codegraff.learn.run.v4"
    assert run["formal_admission_evidence_id"] == original_evidence
    assert run["formal_selection_evidence_id"]
    refused = invoke(graff, workspace, env, "submit", manual_run, succeeds=False)
    assert "FormalReceiptUnsupported" in refused.stderr
    before_manual = int(count.read_text())
    invoke(graff, workspace, env, "promote", manual_run)
    assert int(count.read_text()) >= before_manual + 2
    assert status(graff, workspace, env)["generation"] == 1

    automatic = root / "automatic"
    automatic.mkdir(mode=0o700)
    invoke(graff, automatic, env, "init", "--parent", str(parent.resolve()),
           "--config", str((root / "config.json").resolve()))
    before_auto = int(count.read_text())
    auto_run = run_id_from(invoke(graff, automatic, env, "run", "--auto").stdout)
    assert auto_run
    assert int(count.read_text()) >= before_auto + 4
    assert status(graff, automatic, env)["generation"] == 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    graff = args.graff.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="codegraff-learn-formal."))
    try:
        exercise(graff, root)
    except Exception:
        print(f"formal learning fixture preserved at {root}", file=sys.stderr)
        raise
    shutil.rmtree(root)
    print("formal learning CLI boundaries passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
