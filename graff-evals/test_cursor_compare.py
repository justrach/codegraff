"""Offline admission checks for the opt-in native Cursor comparison."""
import argparse
import copy
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import cursor_compare as compare
import cursor_compare_report as report


class CursorComparisonTests(unittest.TestCase):
    def test_task_subsets_preserve_catalog_order_and_reject_ambiguous_selection(self):
        data = {"tasks": ["a", "b", "c"], "smoke_tasks": ["b"]}
        self.assertEqual(compare.select_tasks(data, False, ["c", "a"]), ["a", "c"])
        self.assertEqual(compare.select_tasks(data, False, None), data["tasks"])
        self.assertEqual(compare.select_tasks(data, True, None), data["smoke_tasks"])
        for smoke, tasks in ((True, ["a"]), (False, ["a", "a"]), (False, ["missing"])):
            with self.assertRaises(ValueError):
                compare.select_tasks(data, smoke, tasks)

    def test_presets_pin_matched_models_and_existing_tasks(self):
        import run
        data = compare.catalog()
        self.assertEqual(len(data["tasks"]), 21)
        self.assertEqual(len(set(data["tasks"])), 21)
        self.assertTrue(set(data["tasks"]) <= set(run.load_tasks()))
        self.assertTrue(set(data["smoke_tasks"]) <= set(data["tasks"]))
        xai = data["presets"]["xai-sub"]
        self.assertEqual((xai["provider"], xai["models"]["graff"], xai["models"]["cursor"], xai["effort"]),
                         ("xai", "grok-4.7", "grok-4.7-high", "high"))
        self.assertEqual(data["presets"]["argon"]["models"]["graff"], "gemini-4-argon")

    def test_cursor_requires_exact_model_and_successful_completion(self):
        rows = [{"type": "system", "model": "Grok 4.7  256K High"},
                {"type": "result", "subtype": "success", "is_error": False, "duration_ms": 2500}]
        stdout = "preamble\n" + "\n".join(json.dumps(r) for r in rows)
        receipt = compare.cursor_receipt(stdout, "Grok 4.7 256K High")
        self.assertTrue(receipt["routing_ok"] and receipt["native_completion_ok"])
        self.assertEqual(receipt["native_task_duration_s"], 2.5)
        self.assertFalse(compare.cursor_receipt(stdout, "Gemini 4 Argon Low")["routing_ok"])
        self.assertFalse(compare.cursor_receipt(json.dumps(rows[0]), "Grok 4.7 256K High")["native_completion_ok"])
        rows[1]["is_error"] = True
        self.assertFalse(compare.cursor_receipt("\n".join(map(json.dumps, rows)), "Grok 4.7 256K High")["native_completion_ok"])

    def test_graff_repl_trace_and_effort_gate_reject_other_routes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trace = root / ".graff/traces/trace.jsonl"
            trace.parent.mkdir(parents=True)
            (root / ".eval-stdout.txt").write_text("reasoning effort: high\n")
            trace.write_text(json.dumps({"ev": "api", "agent": "repl", "provider": "xai", "model": "grok-4.7"}) + "\n")
            self.assertTrue(compare.graff_receipt(root, "xai", "grok-4.7", "high")["routing_ok"])
            self.assertFalse(compare.graff_receipt(root, "codegraff", "grok-4.7", "high")["routing_ok"])
            self.assertFalse(compare.graff_receipt(root, "xai", "grok-4.7", "low")["routing_ok"])
            self.assertFalse(compare.graff_receipt(root, "xai", "grok-4.6", "high")["routing_ok"])

    def test_subscription_snapshot_excludes_refresh_and_cleanup_removes_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.json"
            source.write_text(json.dumps({"access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_at": int(time.time()) + 3600}))
            args = argparse.Namespace(xai_auth=str(source))
            snapshot = compare.access_credentials("xai", args)
            self.assertNotIn("refresh_token", snapshot)
            home = root / "sandbox/.eval-home"
            compare.seed_login(home, "xai", "grok-4.7", snapshot)
            stored = home / ".xai/credentials/graff-oauth.json"
            self.assertEqual(stored.stat().st_mode & 0o777, 0o600)
            compare.cleanup_credentials(root)
            self.assertFalse(stored.exists())
            self.assertTrue(source.is_file())
            source.write_text(json.dumps({"access_token": "fixture-access", "expires_at": 1}))
            with self.assertRaises(ValueError):
                compare.access_credentials("xai", args)

    def test_environment_excludes_api_keys_and_personal_configuration(self):
        with patch.dict(os.environ, {"PATH": "/bin", "XAI_API_KEY": "fixture", "CODEGRAFF_API_KEY": "fixture", "CODEX_HOME": "/private/fixture", "GRAFF_MCP_CONFIG": "/private/mcp"}, clear=True):
            env = compare.safe_environment(Path("/tmp/fixture-cache"))
        self.assertEqual(env["PATH"], "/bin")
        self.assertFalse(set(env) & {"XAI_API_KEY", "CODEGRAFF_API_KEY", "CODEX_HOME", "GRAFF_MCP_CONFIG"})

    def matrix(self):
        meta = {"preset": "xai-sub", "provider": "xai", "models": {"graff": "grok-4.7", "cursor": "grok-4.7-high"},
                "effort": "high", "repetitions": 1, "workers": 2, "tasks": ["task-a", "task-b"], "mode": "full"}
        rows = [{"harness": arm, "task": task, "rep": 1, "suite": "core", "wall_s": 2 if arm == "graff" else 4,
                 "artifact_ok": True, "outcome_ok": True, "routing_ok": True, "native_completion_ok": True,
                 "exit": 0, "timed_out": False, "verifiers_unchanged": True}
                for task in meta["tasks"] for arm in ("graff", "cursor")]
        return meta, rows

    def test_report_rejects_incomplete_duplicate_or_extra_runs(self):
        meta, rows = self.matrix()
        report.validate(meta, rows)
        report.validate(dict(meta, mode="subset"), rows)
        for altered in (rows[:-1], rows + [rows[0]], rows[:-1] + [dict(rows[-1], task="unexpected")]):
            with self.assertRaises(ValueError):
                report.validate(meta, altered)

    def test_report_pairs_only_clean_runs_and_preserves_failures(self):
        meta, rows = self.matrix()
        rows[-1]["routing_ok"] = False
        paired = report.paired_stats(rows)
        self.assertEqual((paired["pairs"], paired["both_clean_passed"], paired["graff_wall_reduction_percent"]), (2, 1, 50.0))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "comparison").mkdir()
            (root / "metadata.json").write_text(json.dumps(meta))
            (root / "comparison/results.jsonl").write_text("\n".join(map(json.dumps, rows)) + "\n")
            result = report.summarize(root, root / "report")
            self.assertEqual(result["summary"]["all"]["cursor"]["clean_pass"], 1)
            self.assertEqual(len(result["failures"]), 1)
            self.assertIsNone(result["summary"]["all"]["graff"]["native_task_duration_mean_s"])


if __name__ == "__main__":
    unittest.main()
