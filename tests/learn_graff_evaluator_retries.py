#!/usr/bin/env python3
"""Focused retry-accounting tests for the model-backed Graff evaluator."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
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
            {"type": "system_prompt", "ok": True, "append": False, "chars": 7},
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
                    Path("/unused-graff"), settings, "prømpt", {"task": "task"}, Path.cwd()
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

            def fake_run_variant(graff, settings, prompt, case, cwd, observer=None):
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

    def test_abrupt_process_loss_recovers_journaled_resources_and_completed_side(self) -> None:
        with tempfile.TemporaryDirectory(prefix="learn-attempt-journal-") as raw_temp:
            temp = Path(raw_temp)
            prompt = "SENSITIVE PROMPT MUST NOT ENTER JOURNAL"
            case = {"task": "private task", "check": {"exact": "ok"}}
            pair = {"case_id": "journal-case", "seed": "f"}
            key = EVALUATOR.attempt_key("a" * 64, pair, "child", prompt)
            journal = Path(".attempt-child.json")
            settings = {"max_attempts": 2}

            def abrupt(graff, settings, prompt, case, cwd, observer=None):
                assert observer is not None
                observer({"latency_ms": 17, "tool_calls": 3, "cost_micros": 13})
                raise SystemExit(99)

            original_cwd = Path.cwd()
            os.chdir(temp)
            try:
                with mock.patch.object(EVALUATOR, "run_variant", side_effect=abrupt), \
                     self.assertRaises(SystemExit):
                    EVALUATOR.run_with_retries(
                        temp / "graff", settings, prompt, case, "child", key, journal,
                    )
                partial = json.loads(journal.read_text(encoding="utf-8"))
                self.assertFalse(partial["complete"])
                self.assertEqual(partial["metrics"], {
                    "latency_ms": 17, "tool_calls": 3, "cost_micros": 13,
                })

                def succeeds(graff, settings, prompt, case, cwd, observer=None):
                    return {
                        "pass": True, "score_ppm": 1_000_000,
                        "latency_ms": 5, "tool_calls": 2, "cost_micros": 11,
                    }

                with mock.patch.object(EVALUATOR, "run_variant", side_effect=succeeds):
                    recovered = EVALUATOR.run_with_retries(
                        temp / "graff", settings, prompt, case, "child", key, journal,
                    )
                self.assertEqual(recovered["latency_ms"], 22)
                self.assertEqual(recovered["tool_calls"], 5)
                self.assertEqual(recovered["cost_micros"], 24)

                with mock.patch.object(
                    EVALUATOR, "run_variant", side_effect=AssertionError("reran completed side"),
                ):
                    cached = EVALUATOR.run_with_retries(
                        temp / "graff", settings, prompt, case, "child", key, journal,
                    )
                self.assertEqual(cached, recovered)
                encoded = journal.read_text(encoding="utf-8")
                self.assertNotIn(prompt, encoded)
                self.assertNotIn(case["task"], encoded)
            finally:
                os.chdir(original_cwd)

    @unittest.skipIf(sys.platform == "win32", "POSIX process-group crash injection")
    def test_real_evaluator_process_death_preserves_observed_usage(self) -> None:
        with tempfile.TemporaryDirectory(prefix="learn-real-process-loss-") as raw_temp:
            temp = Path(raw_temp)
            settings = temp / "settings.json"
            suite = temp / "suite.json"
            request = temp / "request.json"
            response = temp / "response.json"
            parent = temp / "parent.md"
            fake_graff = temp / "fake-graff.py"
            settings.write_text(json.dumps({
                "schema": "codegraff.learn.graff-evaluator.v1",
                "provider": "codex", "model": "test-model", "effort": "low",
                "max_model_calls": 4, "max_tool_calls": 4,
                "max_attempts": 1, "task_timeout_seconds": 30,
            }), encoding="utf-8")
            suite.write_text(json.dumps({
                "schema": "codegraff.learn.suite.v1",
                "cases": [{
                    "id": "crash-case",
                    "payload": {"task": "private crash task", "check": {"exact": "ok"}},
                }],
            }), encoding="utf-8")
            parent.write_text("private parent prompt", encoding="utf-8")
            request.write_text(json.dumps({
                "schema": EVALUATOR.BASELINE_REQUEST_SCHEMA,
                "trial_id": "trial", "cohort_id": "cohort",
                "suite_path": str(suite), "suite_sha256": "suite",
                "parent": {"id": "parent", "path": str(parent)},
                "pairs": [{"case_id": "crash-case", "seed": "0"}],
            }), encoding="utf-8")
            fake_graff.write_text(f"#!{sys.executable}\n" + r'''import json, os, sys, time
complete = os.environ.get("FAKE_COMPLETE") == "1"
assert "--system-prompt" not in sys.argv
for raw in sys.stdin:
    message = json.loads(raw)
    if message.get("type") == "set_system_prompt":
        text = message["text"]
        print(json.dumps({"type":"system_prompt","ok":True,"append":False,"chars":len(text.encode("utf-8"))}), flush=True)
    elif message.get("type") == "set_model":
        print(json.dumps({"type":"model","provider":"codex","model":"test-model"}), flush=True)
    elif message.get("type") == "set_effort":
        print(json.dumps({"type":"effort","level":"low","applies":True}), flush=True)
    elif message.get("type") == "user":
        cost = 0.000011 if complete else 0.000013
        print(json.dumps({"type":"tool_call","cost_usd":cost}), flush=True)
        if complete:
            print(json.dumps({"type":"turn","complete":True,"text":"ok","cost_usd":cost}), flush=True)
            break
        time.sleep(30)
''', encoding="utf-8")
            fake_graff.chmod(0o700)
            command = [
                sys.executable, str(REPO / "examples" / "learn_graff_evaluator.py"),
                str(settings), str(fake_graff), "baseline", str(request), str(response),
            ]
            first_env = {**os.environ, "FAKE_COMPLETE": "0"}
            first = subprocess.Popen(
                command, cwd=temp, env=first_env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True,
            )
            journal = temp / ".attempt-baseline.json"
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if journal.exists():
                    value = json.loads(journal.read_text(encoding="utf-8"))
                    if value.get("metrics", {}).get("cost_micros") == 13:
                        break
                time.sleep(0.02)
            else:
                first.kill()
                self.fail("evaluator did not durably journal the in-flight attempt")
            commands = subprocess.run(
                ["ps", "-Ao", "command="], capture_output=True, text=True, check=True,
            ).stdout
            self.assertNotIn("private parent prompt", commands)
            os.killpg(first.pid, signal.SIGKILL)
            first.communicate(timeout=5)

            completed = subprocess.run(
                command, cwd=temp, env={**os.environ, "FAKE_COMPLETE": "1"},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                timeout=20, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(response.read_text(encoding="utf-8"))["pairs"][0]
            self.assertEqual(result["tool_calls"], 2)
            self.assertEqual(result["cost_micros"], 24)
            self.assertGreaterEqual(result["latency_ms"], 0)
            self.assertFalse(journal.exists())
            encoded_progress = (temp / ".baseline-progress.json").read_text(encoding="utf-8")
            self.assertNotIn("private parent prompt", encoded_progress)
            self.assertNotIn("private crash task", encoded_progress)


if __name__ == "__main__":
    unittest.main()
