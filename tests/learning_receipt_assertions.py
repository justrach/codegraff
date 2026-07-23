"""Independent verifier for aggregate learning OTLP receipt fixtures."""

from __future__ import annotations

import hashlib
import hmac
import re
from typing import Any

SCHEMA = "codegraff.learn.grade.v3"
INTEGER_FIELDS = (
    "pairs", "statistical_units", "parent_passes", "child_passes",
    "child_critical_failures", "critical_regressions", "correctness_regressions",
    "delta_ppm", "mean_score_delta_ppm", "p_value_ppb", "tool_calls_measured",
    "parent_tool_calls", "child_tool_calls",
    "behavior_measured", "parent_behavior_score_ppm", "child_behavior_score_ppm",
    "tool_wins", "tool_losses", "tool_ties",
    "tool_delta_ppm", "tool_p_value_ppb", "parent_cost_micros", "child_cost_micros",
    "latency_measured", "parent_latency_ms", "child_latency_ms", "economy_eligible",
    "eligible", "economy_gate_enabled", "alpha_ppm", "minimum_delta_ppm", "minimum_pairs",
    "minimum_tool_reduction_ppm", "minimum_economy_pairs", "multiplicity",
)
CORE_FIELDS = {
    "prompt_sha", "value", "parent_sha", "run_id", "sig", "judge_id",
    "artifact_sha", "eval_set_hash", "provider_class", "niche",
    "grade_schema", "grade_sig", "delete_token", "run_created_unix_ms",
    "reason", "promotion_mode",
}


def attributes(record: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for item in record["attributes"]:
        value = item["value"]
        if "intValue" in value:
            result[item["key"]] = int(value["intValue"])
        elif "doubleValue" in value:
            result[item["key"]] = float(value["doubleValue"])
        else:
            result[item["key"]] = value["stringValue"]
    return result


def _signature(key: bytes, lines: list[str]) -> str:
    return hmac.new(key, "\n".join(lines).encode(), hashlib.sha256).hexdigest()


def _reduction_ppm(parent: int, child: int) -> int:
    if parent == 0:
        return 0 if child == 0 else -1_000_000
    return max(-1_000_000, int((parent - child) * 1_000_000 / parent))


def _assert_decision(values: dict[str, Any]) -> None:
    significant = lambda name: (
        values[name] * values["multiplicity"] <= values["alpha_ppm"] * 1_000
    )
    discordant = values["tool_wins"] + values["tool_losses"]
    economy = bool(
        values["economy_gate_enabled"]
        and values["child_critical_failures"] == 0
        and values["statistical_units"] >= values["minimum_pairs"]
        and values["correctness_regressions"] == 0
        and values["child_passes"] >= values["parent_passes"]
        and values["mean_score_delta_ppm"] >= 0
        and values["tool_calls_measured"]
        and discordant >= values["minimum_economy_pairs"]
        and values["tool_delta_ppm"] >= values["minimum_tool_reduction_ppm"]
        and significant("tool_p_value_ppb")
    )
    assert values["economy_eligible"] == int(economy)
    if values["child_critical_failures"]:
        reason = "critical_regression" if values["critical_regressions"] else "critical_failure"
        eligible = False
    elif values["statistical_units"] < values["minimum_pairs"]:
        reason, eligible = "minimum_pairs", False
    elif values["promotion_mode"] == "correctness" and values["delta_ppm"] >= values["minimum_delta_ppm"] and significant("p_value_ppb"):
        reason, eligible = "eligible", True
    elif values["promotion_mode"] == "economy" and economy:
        reason, eligible = "economy_eligible", True
    elif values["promotion_mode"] == "economy" and (values["correctness_regressions"] or values["child_passes"] < values["parent_passes"] or values["mean_score_delta_ppm"] < 0):
        reason, eligible = "correctness_regression", False
    elif values["promotion_mode"] == "economy" and not values["tool_calls_measured"]:
        reason, eligible = "tool_calls_unmeasured", False
    elif values["promotion_mode"] == "economy" and discordant < values["minimum_economy_pairs"]:
        reason, eligible = "minimum_economy_pairs", False
    elif values["promotion_mode"] == "economy" and values["tool_delta_ppm"] < values["minimum_tool_reduction_ppm"]:
        reason, eligible = "minimum_tool_reduction", False
    elif values["promotion_mode"] == "economy" and not significant("tool_p_value_ppb"):
        reason, eligible = "economy_not_significant", False
    elif values["delta_ppm"] < values["minimum_delta_ppm"]:
        reason, eligible = "minimum_delta", False
    else:
        reason, eligible = "not_significant", False
    assert (values["reason"], values["eligible"]) == (reason, int(eligible))


def assert_learning_records(
    records: list[dict[str, Any]], run_id: str, key: bytes,
    primary_multiplicity: int, delete_token: str,
) -> None:
    assert records
    for record in records:
        assert record["body"]["stringValue"] == "score"
        values = attributes(record)
        assert set(values) == CORE_FIELDS | set(INTEGER_FIELDS)
        assert values["run_id"] == run_id
        assert values["delete_token"] == delete_token
        assert values["grade_schema"] == SCHEMA
        assert re.fullmatch(r"[0-9a-f]{16}", values["prompt_sha"])
        assert re.fullmatch(r"[0-9a-f]{16}", values["parent_sha"])
        for field in ("run_id", "artifact_sha", "eval_set_hash"):
            assert re.fullmatch(r"[0-9a-f]{64}", values[field])
        event_ms = int(record["timeUnixNano"]) // 1_000_000
        assert 0 <= event_ms - values["run_created_unix_ms"] < 60_000
        expected_multiplicity = primary_multiplicity if values["judge_id"] == "learn-primary-v2" else 1
        assert values["multiplicity"] == expected_multiplicity
        assert values["value"] == values["child_passes"] / values["pairs"]
        assert values["delta_ppm"] == int(
            (values["child_passes"] - values["parent_passes"]) * 1_000_000 / values["pairs"]
        )
        assert values["tool_delta_ppm"] == _reduction_ppm(
            values["parent_tool_calls"], values["child_tool_calls"]
        )
        if values["tool_calls_measured"]:
            assert values["tool_wins"] + values["tool_losses"] + values["tool_ties"] == values["statistical_units"]
        else:
            assert values["tool_wins"] == values["tool_losses"] == values["tool_ties"] == 0
        assert values["behavior_measured"] in (0, 1)
        for field in ("parent_behavior_score_ppm", "child_behavior_score_ppm"):
            assert 0 <= values[field] <= 1_000_000
        if not values["behavior_measured"]:
            assert values["parent_behavior_score_ppm"] == values["child_behavior_score_ppm"] == 0
        _assert_decision(values)

        score_lines = [
            "v2", values["prompt_sha"], values["parent_sha"], f'{values["value"]:.6f}',
            values["run_id"], values["judge_id"], values["artifact_sha"],
            values["eval_set_hash"], values["niche"], values["provider_class"],
        ]
        assert hmac.compare_digest(values["sig"], _signature(key, score_lines))
        grade_lines = [SCHEMA, *score_lines[1:], values["delete_token"],
                       str(values["run_created_unix_ms"]), *(str(values[field]) for field in INTEGER_FIELDS),
                       values["reason"], values["promotion_mode"]]
        assert hmac.compare_digest(values["grade_sig"], _signature(key, grade_lines))

        encoded = repr(values)
        for forbidden in ("prompt_text", "task", "adapter_output", "/Users/", "PRIVATE_"):
            assert forbidden not in encoded
