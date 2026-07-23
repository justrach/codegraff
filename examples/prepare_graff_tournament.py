#!/usr/bin/env python3
"""Prepare a fresh, pinned four-arm learning workspace outside the repo."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import secrets

from learn_graff_suites import (
    fresh_holdout,
    primary_cases,
    statistical_unit_count,
    validate_case_catalog,
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    path.chmod(0o600)


def extract_root_prompt(source: Path) -> str:
    lines = source.read_text(encoding="utf-8").splitlines()
    collecting = False
    result: list[str] = []
    for line in lines:
        if line.startswith("pub const main_system_prompt ="):
            collecting = True
            continue
        if collecting and line == ";":
            break
        if collecting:
            marker = line.find("\\\\")
            if marker >= 0:
                result.append(line[marker + 2 :])
    if not result:
        raise ValueError("could not extract main_system_prompt")
    return "\n".join(result).strip() + "\n"


def pin(path: Path) -> dict[str, str]:
    return {"path": str(path.resolve()), "sha256": digest(path)}


def program_pin(path: Path) -> dict[str, str]:
    return {"program": str(path.resolve()), "sha256": digest(path)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--graff", type=Path, default=Path("zig-out/bin/graff"))
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    workspace = output / "workspace"
    workspace.mkdir(mode=0o700)

    graff = (repo / args.graff).resolve() if not args.graff.is_absolute() else args.graff.resolve()
    mutator = (repo / "examples" / "learn_graff_mutator.py").resolve()
    arms = (repo / "examples" / "learn_graff_arms.json").resolve()
    evaluator = (repo / "examples" / "learn_graff_evaluator.py").resolve()
    evaluator_settings = (repo / "examples" / "learn_graff_evaluator.json").resolve()
    behavior_metrics = (repo / "examples" / "learn_behavior_metrics.py").resolve()
    behavior_scorer = (repo / "scripts" / "score_run.py").resolve()
    case_support = (repo / "examples" / "learn_graff_case.py").resolve()
    for path in (graff, mutator, arms, evaluator, evaluator_settings, behavior_metrics, behavior_scorer, case_support):
        if not path.is_file():
            raise FileNotFoundError(path)

    parent = output / "parent.md"
    parent.write_text(extract_root_prompt(repo / "src" / "prompts.zig"), encoding="utf-8")
    parent.chmod(0o600)
    primary = output / "primary.json"
    holdout = output / "fresh-holdout.json"
    public_cases, hidden_cases = primary_cases(), fresh_holdout()
    validate_case_catalog(public_cases, 60)
    validate_case_catalog(hidden_cases, 40)
    primary_units = statistical_unit_count(public_cases)
    holdout_units = statistical_unit_count(hidden_cases)
    if primary_units < 40 or holdout_units < 40:
        raise ValueError("primary and holdout each require 40 independent statistical units")
    write_json(primary, {"schema": "codegraff.learn.suite.v1", "suite_id": "graff-primary-v7", "cases": public_cases})
    write_json(holdout, {"schema": "codegraff.learn.suite.v1", "suite_id": "fresh-" + secrets.token_hex(8), "cases": hidden_cases})

    config = {
        "schema": "codegraff.learn.config.v1",
        "agent_name": "graff-root-tournament",
        "agent_description": "manual-only four-arm root prompt tournament",
        "mutation_instruction": "Patch exactly one configured paragraph with one concise, role-specific behavioral clause. Preserve every other byte and every safety or authority invariant.",
        "mutator": {
            **program_pin(mutator), "args": [str(arms), str(graff)],
            "inputs": [pin(arms), pin(graff)], "pass_env": ["CODEX_HOME"],
        },
        "evaluator": {
            **program_pin(evaluator), "args": [str(evaluator_settings), str(graff)],
            "inputs": [pin(evaluator_settings), pin(graff), pin(behavior_metrics), pin(behavior_scorer), pin(case_support)],
            "pass_env": ["CODEX_HOME"],
        },
        "evaluation_suite": pin(primary),
        "holdout_suite": pin(holdout),
        "limits": {"mutator_timeout_ms": 600000, "evaluator_timeout_ms": 1800000},
        "gate": {
            "alpha_ppm": 50000,
            "minimum_delta_ppm": 50000,
            "minimum_pairs": 40,
            "economy_gate_enabled": True,
            "promotion_mode": "economy",
            "minimum_tool_reduction_ppm": 100000,
            "minimum_economy_pairs": 10,
            "require_all_candidates": True,
            "default_candidates": 4,
            "default_repetitions": 1,
        },
        "auto": {"enabled": False},
        "cohort": {"provider": "codex", "model": "gpt-5.4-mini", "task_family": "coding-flow", "adapter_version": "graff-eval-v8", "verifier_version": "behavior-audited-v7"},
    }
    config_path = output / "config.json"
    write_json(config_path, config)
    print(json.dumps({
        "workspace": str(workspace), "parent": str(parent), "config": str(config_path),
        "primary_sha256": digest(primary), "holdout_sha256": digest(holdout),
        "primary_cases": len(public_cases), "holdout_cases": len(hidden_cases),
        "primary_units": primary_units, "holdout_units": holdout_units,
    }, indent=2))


if __name__ == "__main__":
    main()
