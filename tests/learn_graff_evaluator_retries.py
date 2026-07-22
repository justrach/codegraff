#!/usr/bin/env python3
"""Focused retry-accounting tests for the model-backed Graff evaluator."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "learn_graff_evaluator", REPO / "examples" / "learn_graff_evaluator.py"
)
assert SPEC is not None and SPEC.loader is not None
EVALUATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVALUATOR)


class RetryAccountingTests(unittest.TestCase):
    def test_progress_is_atomic_request_bound_pair_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="learn-progress-test-") as raw_temp:
            temp = Path(raw_temp)
            request_path = temp / "request.json"
            progress_path = temp / "progress.json"
            pairs = [
                {"case_id": "one", "seed": "a"},
                {"case_id": "two", "seed": "b"},
            ]
            request_path.write_text(json.dumps({"pairs": pairs}), encoding="utf-8")
            request_sha256, empty = EVALUATOR.load_progress(
                progress_path, request_path, pairs,
            )
            self.assertEqual(empty, [])
            completed = [{"case_id": "one", "seed": "a", "child_pass": True}]
            EVALUATOR.save_progress(progress_path, request_sha256, completed)
            loaded_sha256, loaded = EVALUATOR.load_progress(
                progress_path, request_path, pairs,
            )
            self.assertEqual(loaded_sha256, request_sha256)
            self.assertEqual(loaded, completed)
            self.assertFalse((temp / "progress.json.tmp").exists())

            request_path.write_text(json.dumps({"pairs": list(reversed(pairs))}), encoding="utf-8")
            with mock.patch.object(EVALUATOR.sys, "stderr", io.StringIO()), \
                 self.assertRaises(SystemExit):
                EVALUATOR.load_progress(progress_path, request_path, list(reversed(pairs)))

    def test_terminal_error_carries_observed_resources(self) -> None:
        events = [
            {"type": "model", "provider": "codex", "model": "test-model"},
            {"type": "effort", "level": "low", "applies": True},
            *({"type": "tool_call"} for _ in range(4)),
            {"type": "error", "message": "retry me", "cost_usd": 0.000020},
        ]

        class FakeProcess:
            stdin = io.StringIO()
            stdout = iter(json.dumps(event) + "\n" for event in events)
            stderr = io.StringIO()

            def wait(self, timeout=None):
                return 0

            def kill(self):
                return None

        class FakeTimer:
            def __init__(self, *args, **kwargs):
                pass

            def start(self):
                pass

            def cancel(self):
                pass

        settings = {
            "provider": "codex", "model": "test-model", "effort": "low",
            "max_model_calls": 8, "max_tool_calls": 8, "task_timeout_seconds": 10,
        }
        with mock.patch.object(EVALUATOR.subprocess, "Popen", return_value=FakeProcess()), \
             mock.patch.object(EVALUATOR.threading, "Timer", FakeTimer), \
             mock.patch.object(EVALUATOR.time, "monotonic", side_effect=(1.0, 1.03)):
            with self.assertRaises(EVALUATOR.EvaluationAttemptError) as raised:
                EVALUATOR.run_variant(
                    Path("/unused-graff"), settings, "prompt", {"task": "task"}, Path.cwd()
                )
        self.assertEqual(raised.exception.tool_calls, 4)
        self.assertEqual(raised.exception.latency_ms, 30)
        self.assertEqual(raised.exception.cost_micros, 20)

    def test_failed_attempt_resources_are_added_to_success(self) -> None:
        with tempfile.TemporaryDirectory(prefix="learn-retry-test-") as raw_temp:
            temp = Path(raw_temp)
            settings_path = temp / "settings.json"
            suite_path = temp / "suite.json"
            request_path = temp / "request.json"
            response_path = temp / "response.json"
            parent_path = temp / "parent.md"
            child_path = temp / "child.md"
            settings_path.write_text(json.dumps({
                "schema": "codegraff.learn.graff-evaluator.v1",
                "provider": "codex",
                "model": "test-model",
                "effort": "low",
                "max_model_calls": 8,
                "max_tool_calls": 8,
                "max_attempts": 2,
                "task_timeout_seconds": 10,
            }), encoding="utf-8")
            suite_path.write_text(json.dumps({
                "schema": "codegraff.learn.suite.v1",
                "cases": [{
                    "id": "retry-case",
                    "payload": {
                        "task": "return ok",
                        "setup_files": {"fixture.txt": "clean"},
                        "check": {"exact": "ok"},
                    },
                }],
            }), encoding="utf-8")
            parent_path.write_text("parent", encoding="utf-8")
            child_path.write_text("child", encoding="utf-8")
            request_path.write_text(json.dumps({
                "schema": EVALUATOR.REQUEST_SCHEMA,
                "trial_id": "trial",
                "candidate_index": 0,
                "cohort_id": "cohort",
                "suite_path": str(suite_path),
                "suite_sha256": "suite",
                "parent": {"id": "parent", "path": str(parent_path)},
                "child": {"id": "child", "path": str(child_path)},
                "pairs": [{"case_id": "retry-case", "seed": "0"}],
            }), encoding="utf-8")

            child_attempts = 0
            child_scratch: list[Path] = []

            def fake_run_variant(graff, settings, prompt, case, cwd):
                nonlocal child_attempts
                self.assertEqual((cwd / "fixture.txt").read_text(encoding="utf-8"), "clean")
                if prompt == "parent":
                    return {
                        "pass": True, "score_ppm": 1_000_000,
                        "cost_micros": 11, "latency_ms": 10, "tool_calls": 5,
                    }
                child_attempts += 1
                child_scratch.append(cwd)
                self.assertFalse((cwd / "failed-attempt.txt").exists())
                if child_attempts == 1:
                    (cwd / "failed-attempt.txt").write_text("dirty", encoding="utf-8")
                    raise EVALUATOR.EvaluationAttemptError(
                        "failed after tools", latency_ms=30, tool_calls=4, cost_micros=20
                    )
                return {
                    "pass": True, "score_ppm": 1_000_000,
                    "cost_micros": 10, "latency_ms": 15, "tool_calls": 2,
                }

            original_cwd = Path.cwd()
            os.chdir(temp)
            try:
                with mock.patch.object(EVALUATOR, "executable_snapshot", side_effect=lambda path: path), \
                     mock.patch.object(EVALUATOR, "run_variant", side_effect=fake_run_variant):
                    EVALUATOR.evaluate(
                        settings_path, temp / "unused-graff", request_path, response_path
                    )
            finally:
                os.chdir(original_cwd)

            pair = json.loads(response_path.read_text(encoding="utf-8"))["pairs"][0]
            self.assertEqual(child_attempts, 2)
            self.assertEqual(len(set(child_scratch)), 2)
            self.assertEqual(pair["child_tool_calls"], 6)
            self.assertEqual(pair["child_latency_ms"], 45)
            self.assertEqual(pair["child_cost_micros"], 30)
            self.assertGreater(pair["child_tool_calls"], pair["parent_tool_calls"])
            self.assertGreater(pair["child_latency_ms"], pair["parent_latency_ms"])
            self.assertGreater(pair["child_cost_micros"], pair["parent_cost_micros"])
            self.assertNotIn("attempt_count", pair)


if __name__ == "__main__":
    unittest.main()
