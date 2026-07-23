"""Quality-diversity metrics for model-shape benchmark reports."""

from __future__ import annotations

from typing import Any, Iterable


def quality_diversity(
    rows: list[dict[str, Any]],
    arms: Iterable[Any],
    tasks: Iterable[Any],
) -> dict[str, Any]:
    """Build a tiny correctness-first archive over declared task niches.

    QD score is the sum of each niche elite's normalized correctness. Qualified
    coverage counts niches whose elite is fully correct with the requested
    provider/model shape. Tool calls and wall time only break correctness ties.
    """
    niches = sorted({task.niche for task in tasks})
    task_niches = {task.name: task.niche for task in tasks}
    result: dict[str, Any] = {
        "definition": {
            "cell": "task_niche",
            "fitness": "shape_valid_cases_passed / cases_total",
            "elite_tiebreak": "fewer_tool_calls_then_lower_wall_ms",
            "qualified": "fitness == 1.0",
        },
        "niches": niches,
        "arms": {},
    }
    for arm in arms:
        archive: dict[str, Any] = {}
        for niche in niches:
            candidates = [
                row
                for row in rows
                if row["arm"] == arm.name and task_niches.get(row["task"]) == niche
            ]
            if not candidates:
                continue

            def fitness(row: dict[str, Any]) -> float:
                if not row["metrics"].get("shape_valid", True):
                    return 0.0
                total = row["checks"]["total"]
                return row["checks"]["passed"] / total if total else 0.0

            elite = max(
                candidates,
                key=lambda row: (
                    fitness(row),
                    -row["metrics"]["tool_calls"],
                    -row["wall_ms"],
                ),
            )
            archive[niche] = {
                "task": elite["task"],
                "repetition": elite.get("repetition", 1),
                "fitness": fitness(elite),
                "fully_correct": fitness(elite) == 1.0,
                "tool_calls": elite["metrics"]["tool_calls"],
                "wall_ms": elite["wall_ms"],
            }
        qd_score = sum(cell["fitness"] for cell in archive.values())
        qualified = sum(cell["fully_correct"] for cell in archive.values())
        result["arms"][arm.name] = {
            "archive": archive,
            "occupied_cells": len(archive),
            "qualified_cells": qualified,
            "qualified_coverage": qualified / len(niches) if niches else 0.0,
            "qd_score": qd_score,
            "normalized_qd_score": qd_score / len(niches) if niches else 0.0,
            "elite_tool_calls": sum(
                cell["tool_calls"] for cell in archive.values()
            ),
        }
    return result
