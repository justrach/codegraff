#!/usr/bin/env python3
"""Integrity tests for the CI gate in front of release and beta publication."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("wait_for_ci", Path(__file__).with_name("wait-for-ci.py"))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def run(run_id: int, status: str, conclusion: str = "") -> dict:
    return {"databaseId": run_id, "status": status, "conclusion": conclusion, "url": f"u/{run_id}"}


class WaitForCiTests(unittest.TestCase):
    def test_waits_until_a_run_exists(self) -> None:
        self.assertEqual(gate.verdict([])[0], "wait")

    def test_waits_while_ci_runs(self) -> None:
        self.assertEqual(gate.verdict([run(1, "in_progress")])[0], "wait")
        self.assertEqual(gate.verdict([run(1, "queued")])[0], "wait")

    def test_only_success_passes(self) -> None:
        self.assertEqual(gate.verdict([run(1, "completed", "success")])[0], "pass")
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", ""):
            self.assertEqual(gate.verdict([run(1, "completed", conclusion)])[0], "fail", conclusion)

    def test_newest_run_decides(self) -> None:
        self.assertEqual(gate.verdict([run(2, "completed", "failure"), run(1, "completed", "success")])[0], "fail")
        self.assertEqual(gate.verdict([run(1, "completed", "failure"), run(2, "in_progress")])[0], "wait")


if __name__ == "__main__":
    unittest.main()
