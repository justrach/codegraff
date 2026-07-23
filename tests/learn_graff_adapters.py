#!/usr/bin/env python3
"""Offline protocol tests for the pinned model-backed learning adapters."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MUTATOR = ROOT / "examples" / "learn_graff_mutator.py"
EVALUATOR = ROOT / "examples" / "learn_graff_evaluator.py"
ARMS = ROOT / "examples" / "learn_graff_arms.json"
SETTINGS = ROOT / "examples" / "learn_graff_evaluator.json"
PREPARE = ROOT / "examples" / "prepare_graff_tournament.py"

FAKE_GRAFF = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if os.environ.get("HARNESS_CLIENT") == "learn-evaluator":
    assert "--system-prompt" not in args
system = args[args.index("--system-prompt") + 1] if "--system-prompt" in args else None
turns = 0
for raw in sys.stdin:
    value = json.loads(raw)
    kind = value.get("type")
    if kind == "set_system_prompt":
        system = value["text"]
        event = {"type":"system_prompt","ok":True,"append":False,"chars":len(system.encode("utf-8"))}
    elif kind == "set_model":
        event = {"type":"model","ok":True,"provider":value["provider"],"model":value["model"]}
    elif kind == "set_effort":
        event = {"type":"effort","ok":True,"level":value["level"],"applies":True}
    elif kind == "user":
        assert system is not None
        if "concise clause" in system:
            turns += 1
            text = "invalid first attempt" if turns == 1 else json.dumps({
                "clause":"Added focused rule.",
            }, separators=(",", ":"))
            event = {"type":"turn","text":text,"complete":True,"cost_usd":0.001}
        else:
            marker = pathlib.Path(sys.argv[0]).parent / ".eval-retry-once"
            if not marker.exists():
                marker.write_text("retry")
                raise SystemExit(0)
            print(json.dumps({"type":"tool_call","name":"read_file","input":{}}), flush=True)
            event = {"type":"turn","text":"42","complete":True,"cost_usd":0.002}
    else:
        event = {"type":"error","message":"unexpected request"}
    print(json.dumps(event), flush=True)
'''


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")


def assert_patch_boundaries() -> None:
    apply_patch = runpy.run_path(str(MUTATOR))["apply_patch"]
    parent = "Target SAFE paragraph.\n\nInvariant.\n"
    target = "Target SAFE paragraph."
    protected = ["SAFE", "Invariant."]

    valid = json.dumps({"clause": "Added rule."})
    child, violations = apply_patch(valid, parent, target, protected, 128, 4096)
    assert child == "Target SAFE paragraph. Added rule.\n\nInvariant.\n"
    assert not violations

    replacement_parent = "Target paragraph.\n\nProtected invariant.\n"
    replacement, violations = apply_patch(
        json.dumps({"clause": "Read the exact span once."}),
        replacement_parent,
        "Target paragraph.",
        ["Protected invariant."],
        128,
        4096,
        "replace",
    )
    assert replacement == "Read the exact span once.\n\nProtected invariant.\n"
    assert not violations

    cases = (
        (json.dumps({"clause": "Added rule.", "extra": True}), 128, 4096,
         "only clause"),
        (json.dumps({"clause": "SAFE"}), 128, 4096,
         "protected substrings"),
        (json.dumps({"clause": "x" * 200}), 64, 4096,
         "changed more than"),
        (valid, 128, len(parent.encode("utf-8")), "merged prompt exceeded"),
    )
    for raw, changed_limit, total_limit, expected in cases:
        child, violations = apply_patch(
            raw, parent, target, protected, changed_limit, total_limit,
        )
        assert child is None
        assert any(expected in violation for violation in violations)


def run() -> None:
    assert_patch_boundaries()
    with tempfile.TemporaryDirectory(prefix="learn-adapters-") as raw:
        root = Path(raw)
        fake = root / "graff"
        fake.write_text(FAKE_GRAFF, encoding="utf-8")
        fake.chmod(0o700)

        subprocess.run([sys.executable, str(MUTATOR), "--validate", str(ARMS)], check=True)
        subprocess.run([sys.executable, str(EVALUATOR), "--validate", str(SETTINGS)], check=True)

        # Keep this protocol fixture small while exercising the same invariant
        # preservation contract as the production arm configuration.
        test_arms = root / "arms.json"
        arms = json.loads(ARMS.read_text(encoding="utf-8"))
        arms["protected_substrings"] = ["Target paragraph.", "Protected invariant."]
        arms["targets"] = {"root_workflow": "Target paragraph."}
        for arm in arms["arms"]:
            arm["placement"] = "append"
        arms["maximum_changed_bytes"] = 128
        write_json(test_arms, arms)

        parent = root / "parent.genome"
        child = root / "child.genome"
        parent.write_text("Target paragraph.\n\nProtected invariant.\n", encoding="utf-8")
        mutation_request = root / "mutation-request.json"
        mutation_response = root / "mutation-response.json"
        parent_id = "a" * 64
        write_json(mutation_request, {
            "schema": "codegraff.learn.mutation.request.v1",
            "trial_id": "b" * 64,
            "candidate_index": 0,
            "seed": "c" * 64,
            "parent": {"id": parent_id, "path": str(parent)},
            "child_path": str(child),
            "maximum_bytes": 4096,
            "instruction": "improve tool economy",
        })
        subprocess.run([
            sys.executable, str(MUTATOR), str(test_arms), str(fake), "mutate",
            str(mutation_request), str(mutation_response),
        ], cwd=root, check=True)
        mutation = json.loads(mutation_response.read_text())
        assert child.read_text() == "Target paragraph. Added focused rule.\n\nProtected invariant.\n"
        assert mutation["description"] == "sol-semantic-boundaries (gpt-5.6-sol/high)"
        assert mutation["child_sha256"] == hashlib.sha256(child.read_bytes()).hexdigest()

        fixed_arms_path = root / "fixed-arms.json"
        fixed_arms = json.loads(test_arms.read_text(encoding="utf-8"))
        fixed_arms["protected_substrings"] = ["Protected invariant."]
        fixed_arms["arms"][1]["placement"] = "replace"
        fixed_arms["arms"][1]["fixed_clause"] = "Read the exact span once."
        write_json(fixed_arms_path, fixed_arms)
        fixed_child = root / "fixed-child.genome"
        fixed_request = root / "fixed-request.json"
        fixed_response = root / "fixed-response.json"
        fixed_request_value = json.loads(mutation_request.read_text(encoding="utf-8"))
        fixed_request_value["candidate_index"] = 1
        fixed_request_value["child_path"] = str(fixed_child)
        write_json(fixed_request, fixed_request_value)
        subprocess.run([
            sys.executable, str(MUTATOR), str(fixed_arms_path), str(root / "missing-graff"),
            "mutate", str(fixed_request), str(fixed_response),
        ], cwd=root, check=True)
        assert fixed_child.read_text() == "Read the exact span once.\n\nProtected invariant.\n"
        assert "frozen confirmation" in json.loads(fixed_response.read_text())["description"]

        invalid_fake = root / "graff-invalid"
        invalid_fake.write_text(FAKE_GRAFF.replace(
            'text = "invalid first attempt" if turns == 1 else json.dumps({\n'
            '                "clause":"Added focused rule.",\n'
            '            }, separators=(",", ":"))',
            'text = json.dumps({"clause":"Target paragraph."})',
        ), encoding="utf-8")
        invalid_fake.chmod(0o700)
        fallback_response = root / "fallback-response.json"
        child.unlink()
        subprocess.run([
            sys.executable, str(MUTATOR), str(test_arms), str(invalid_fake), "mutate",
            str(mutation_request), str(fallback_response),
        ], cwd=root, check=True)
        fallback = json.loads(fallback_response.read_text())
        assert child.read_bytes() == parent.read_bytes()
        assert fallback["description"].endswith("validation fallback: parent")

        prepared = root / "prepared"
        output = subprocess.run([
            sys.executable, str(PREPARE), str(prepared), "--repo", str(ROOT),
            "--graff", str(fake),
        ], check=True, text=True, capture_output=True)
        preparation = json.loads(output.stdout)
        primary = json.loads((prepared / "primary.json").read_text(encoding="utf-8"))
        holdout = json.loads((prepared / "fresh-holdout.json").read_text(encoding="utf-8"))
        config = json.loads((prepared / "config.json").read_text(encoding="utf-8"))
        assert preparation["primary_cases"] == len(primary["cases"]) == 60
        assert preparation["holdout_cases"] == len(holdout["cases"]) == 40
        assert len({case["id"] for case in primary["cases"]}) == 60
        assert len({case["id"] for case in holdout["cases"]}) == 40
        primary_ids = [case["id"] for case in primary["cases"]]
        holdout_ids = [case["id"] for case in holdout["cases"]]
        unit_count = lambda cases: len({
            case.get("statistical_unit_id", case["id"]) for case in cases
        })
        assert preparation["primary_units"] == unit_count(primary["cases"]) == 44
        assert preparation["holdout_units"] == unit_count(holdout["cases"]) == 40
        for prefix, unit in (
            ("edit-noop-random-", "edit-noop"),
            ("edit-filter-random-", "edit-filter"),
            ("edit-dedupe-random-", "edit-dedupe"),
            ("edit-copy-random-", "edit-copy"),
        ):
            clustered = [case for case in primary["cases"] if case["id"].startswith(prefix)]
            assert len(clustered) == 5
            assert {case["statistical_unit_id"] for case in clustered} == {unit}
        assert [sum(item.startswith(prefix) for item in primary_ids) for prefix in (
            "semantic-", "edit-", "dependency-", "economy-",
        )] == [10, 30, 10, 10]
        assert [sum(item.startswith(prefix) for item in holdout_ids) for prefix in (
            "fresh-sem-", "fresh-edit-", "fresh-dep-", "fresh-econ-", "fresh-shift-",
        )] == [7, 11, 7, 7, 8]
        configured_target = json.loads(ARMS.read_text(encoding="utf-8"))["targets"]["root_workflow"]
        prepared_parent = (prepared / "parent.md").read_text(encoding="utf-8")
        assert prepared_parent.count(configured_target) == 1
        assert config["gate"]["default_candidates"] == 4
        assert config["gate"]["promotion_mode"] == "economy"
        assert config["gate"]["require_all_candidates"] is True
        assert config["gate"]["minimum_pairs"] <= preparation["primary_units"]
        assert config["gate"]["minimum_pairs"] <= preparation["holdout_units"]
        assert config["cohort"]["adapter_version"] == "graff-eval-v7"
        assert config["cohort"]["verifier_version"] == "clustered-exact-v6"
        assert config["auto"] == {"enabled": False}

        suite = root / "suite.json"
        write_json(suite, {
            "schema": "codegraff.learn.suite.v1",
            "suite_id": "offline",
            "cases": [{
                "id": "answer",
                "payload": {"task": "Reply 42", "check": {"exact": "42"}},
            }],
        })
        evaluation_request = root / "evaluation-request.json"
        evaluation_response = root / "evaluation-response.json"
        write_json(evaluation_request, {
            "schema": "codegraff.learn.evaluation.request.v1",
            "trial_id": "b" * 64,
            "candidate_index": 0,
            "cohort_id": "d" * 64,
            "suite_sha256": hashlib.sha256(suite.read_bytes()).hexdigest(),
            "suite_path": str(suite),
            "parent": {"id": parent_id, "path": str(parent)},
            "child": {"id": "e" * 64, "path": str(child)},
            "repetitions": 1,
            "pairs": [{"case_id": "answer", "seed": "f" * 64, "critical": False}],
        })
        subprocess.run([
            sys.executable, str(EVALUATOR), str(SETTINGS), str(fake), "evaluate",
            str(evaluation_request), str(evaluation_response),
        ], cwd=root, check=True)
        result = json.loads(evaluation_response.read_text())["pairs"][0]
        assert result["parent_pass"] and result["child_pass"]
        assert result["tool_calls_measured"] is True
        assert result["latency_measured"] is True
        assert result["parent_tool_calls"] == result["child_tool_calls"] == 1
        assert result["parent_cost_micros"] == result["child_cost_micros"] == 2000

        baseline_request = root / "baseline-request.json"
        baseline_response = root / "baseline-response.json"
        write_json(baseline_request, {
            "schema": "codegraff.learn.primary-baseline.request.v1",
            "trial_id": "b" * 64,
            "cohort_id": "d" * 64,
            "suite_sha256": hashlib.sha256(suite.read_bytes()).hexdigest(),
            "suite_path": str(suite),
            "parent": {"id": parent_id, "path": str(parent)},
            "repetitions": 1,
            "pairs": [{"case_id": "answer", "seed": "f" * 64, "critical": False}],
        })
        subprocess.run([
            sys.executable, str(EVALUATOR), str(SETTINGS), str(fake), "baseline",
            str(baseline_request), str(baseline_response),
        ], cwd=root, check=True)
        baseline = json.loads(baseline_response.read_text())
        assert baseline["schema"] == "codegraff.learn.primary-baseline.response.v1"
        assert baseline["parent_id"] == parent_id
        assert baseline["pairs"] == [{
            "case_id": "answer", "seed": "f" * 64,
            "pass": True, "score_ppm": 1_000_000,
            "cost_micros": 2000, "latency_ms": baseline["pairs"][0]["latency_ms"],
            "latency_measured": True, "tool_calls_measured": True, "tool_calls": 1,
        }]

        primary_request = root / "primary-request.json"
        primary_response = root / "primary-response.json"
        write_json(primary_request, {
            "schema": "codegraff.learn.primary-evaluation.request.v1",
            "trial_id": "b" * 64,
            "candidate_index": 0,
            "cohort_id": "d" * 64,
            "suite_sha256": hashlib.sha256(suite.read_bytes()).hexdigest(),
            "suite_path": str(suite),
            "parent_id": parent_id,
            "baseline": {
                "request_evidence_id": "1" * 64,
                "response_evidence_id": "2" * 64,
                "path": str(baseline_response),
            },
            "child": {"id": "e" * 64, "path": str(child)},
            "repetitions": 1,
            "pairs": [{"case_id": "answer", "seed": "f" * 64, "critical": False}],
        })
        subprocess.run([
            sys.executable, str(EVALUATOR), str(SETTINGS), str(fake), "evaluate_primary",
            str(primary_request), str(primary_response),
        ], cwd=root, check=True)
        primary_result = json.loads(primary_response.read_text())["pairs"][0]
        baseline_result = baseline["pairs"][0]
        assert primary_result["parent_pass"] == baseline_result["pass"]
        assert primary_result["parent_score_ppm"] == baseline_result["score_ppm"]
        assert primary_result["parent_cost_micros"] == baseline_result["cost_micros"]
        assert primary_result["parent_latency_ms"] == baseline_result["latency_ms"]
        assert primary_result["parent_tool_calls"] == baseline_result["tool_calls"]
        assert primary_result["child_pass"] is True


if __name__ == "__main__":
    run()
    print("Graff learning adapter tests passed")
