#!/usr/bin/env python3
"""Offline integrity checks for the live model-shape benchmark."""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import model_shape
from model_shape_frontend_tasks import TASKS as FRONTEND_TASKS
from model_shape_metrics import quality_diversity
from model_shape_tasks import TASKS


def fake_run(
    task: str,
    arm: str,
    passed: int,
    wall_ms: int,
    tools: int,
    repetition: int = 1,
) -> dict:
    return {
        "task": task,
        "arm": arm,
        "repetition": repetition,
        "wall_ms": wall_ms,
        "checks": {
            "passed": passed,
            "total": 9,
            "fully_correct": passed == 9,
        },
        "metrics": {
            "tool_calls": tools,
            "api_calls": 4,
            "context_tokens_sum": 100,
            "response_bytes_sum": 200,
            "provider_retries": 0,
            "shape_valid": True,
        },
    }


def check_selection() -> None:
    arms = (
        model_shape.arm_for("codex:gpt-5.6-sol"),
        model_shape.arm_for("codex:gpt-5.6-terra"),
    )
    rows = []
    for index in range(3):
        rows.append(fake_run(f"task-{index}", "all-sol", 9, 120, 12))
        rows.append(fake_run(f"task-{index}", "sol-terra", 9, 90, 8))
    comparison = model_shape.compare(rows, arms)
    assert comparison["provisional_winner"] == "sol-terra"
    assert comparison["selection_policy"] == "correctness_first_then_tool_economy"
    assert comparison["manual_promotion_required"] is True
    assert comparison["observed_pairs"] == 3
    assert comparison["total_wall_delta_pct"] == -25

    rows[-1]["checks"]["passed"] = 8
    comparison = model_shape.compare(rows, arms)
    assert comparison["provisional_winner"] == "all-sol"

    powered = []
    for repetition in range(1, 8):
        for index in range(3):
            powered.append(
                fake_run(
                    f"task-{index}", "all-sol", 9, 120, 12, repetition
                )
            )
            powered.append(
                fake_run(
                    f"task-{index}", "sol-terra", 9, 90, 8, repetition
                )
            )
    comparison = model_shape.compare(powered, arms)
    assert comparison["observed_pairs"] == 21
    assert comparison["manual_promotion_required"] is False

    powered[-1]["metrics"]["shape_valid"] = False
    comparison = model_shape.compare(powered, arms)
    assert comparison["provisional_winner"] == "all-sol"
    assert comparison["valid_shapes"]["sol-terra"] == 20
    assert comparison["manual_promotion_required"] is True


def check_fixtures() -> None:
    expected_starter_scores = {
        "expiring_lru": 2,
        "route_precedence": 3,
        "atomic_inventory": 0,
        "responsive_portfolio": 0,
        "accessible_modal": 1,
        "persistent_theme_form": 0,
    }
    with tempfile.TemporaryDirectory(prefix="shape-fixture-check-") as raw:
        base = Path(raw)
        for task in TASKS + FRONTEND_TASKS:
            root = base / task.name
            digest = model_shape.initialize_workspace(root, task)
            public_test = root / "test_public.py"
            compile(
                public_test.read_text(encoding="utf-8"),
                str(public_test),
                "exec",
            )
            grade = model_shape.run_checks(task, root, digest)
            assert grade["total"] == task.visible_count + task.hidden_count == 9
            assert grade["passed"] == expected_starter_scores[task.name]
            assert len(grade["hidden_results"]) == task.hidden_count == 5
            assert grade["tests_unchanged"] is True


def check_quality_diversity() -> None:
    arms = (
        model_shape.arm_for("codex:gpt-5.6-sol"),
        model_shape.arm_for("kimi:k3"),
    )
    rows = []
    for task in FRONTEND_TASKS:
        rows.append(fake_run(task.name, "all-sol", 8, 120, 12))
        rows.append(fake_run(task.name, "sol-kimi-k3", 9, 100, 8))
    qd = quality_diversity(rows, arms, FRONTEND_TASKS)
    baseline = qd["arms"]["all-sol"]
    kimi = qd["arms"]["sol-kimi-k3"]
    assert baseline["qualified_coverage"] == 0
    assert round(baseline["normalized_qd_score"], 6) == round(8 / 9, 6)
    assert kimi["qualified_coverage"] == 1
    assert kimi["qd_score"] == 3
    assert kimi["elite_tool_calls"] == 24


def main() -> None:
    check_selection()
    check_fixtures()
    check_quality_diversity()
    print("ok    model-shape selection policy and synthetic fixtures")


if __name__ == "__main__":
    main()
