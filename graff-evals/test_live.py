"""Fast unit tests for live scoring and G5 — no zig, no model."""
import os
import tempfile
import unittest

import report
import live_setup
import named_check


class TaskPass(unittest.TestCase):
    def test_live_two_of_three(self):
        self.assertTrue(report.task_pass(2, 3, "live"))
        self.assertTrue(report.task_pass(3, 3, "live"))
        self.assertFalse(report.task_pass(1, 3, "live"))

    def test_lite_needs_all(self):
        self.assertFalse(report.task_pass(2, 3, "core"))
        self.assertTrue(report.task_pass(3, 3, "core"))


class LiveCost(unittest.TestCase):
    def test_failed_rep_contributes_zero_usd(self):
        recs = [
            {"harness": "g", "task": "a", "outcome_ok": True, "list_usd": 0.40,
             "tok_in": 100, "tok_out": 10, "tok_calls": 4, "wall_s": 1},
            {"harness": "g", "task": "a", "outcome_ok": False, "list_usd": 0.01,
             "tok_in": 5, "tok_out": 1, "tok_calls": 1, "wall_s": 1},
            {"harness": "g", "task": "a", "outcome_ok": True, "list_usd": 0.50,
             "tok_in": 200, "tok_out": 20, "tok_calls": 5, "wall_s": 1},
        ]
        live = report.bucket(recs, suite="live")["g"]
        lite = report.bucket(recs, suite="core")["g"]
        self.assertAlmostEqual(live["usd"], 0.90)
        self.assertEqual(live["tin"], 300)
        self.assertEqual(live["calls"], 9)
        self.assertAlmostEqual(lite["usd"], 0.91)
        self.assertEqual(live["task_ok"], 1)

    def test_failed_task_is_zero_not_a_cheap_average(self):
        recs = [
            {"harness": "g", "task": "miss", "outcome_ok": False, "list_usd": 0.00,
             "tok_in": 3, "tok_out": 0, "tok_calls": 0, "wall_s": 1},
        ]
        b = report.bucket(recs, suite="live")["g"]
        self.assertEqual(b["usd"], 0.0)
        self.assertEqual(b["usd_n"], 0)
        self.assertEqual(b["task_ok"], 0)


class NamedCheck(unittest.TestCase):
    def test_failed_name_is_red(self):
        out = "error: 'agent_context.test.inputOverCompactThreshold (#193): local estimate gates a pre-send compact' failed:\n"
        self.assertFalse(named_check.named_ok(out, "inputOverCompactThreshold (#193): local estimate gates a pre-send compact"))

    def test_other_failure_is_still_green_for_this_name(self):
        out = "error: 'acp.test.userMessage promotes a GUI @[image] attachment' terminated with signal ABRT\n"
        self.assertTrue(named_check.named_ok(out, "inputOverCompactThreshold (#193): local estimate gates a pre-send compact"))


class Spoilers(unittest.TestCase):
    def test_spec_md_is_a_g5_hit(self):
        td = tempfile.mkdtemp()
        with open(os.path.join(td, "SPEC.md"), "w") as f:
            f.write("do the thing")
        hits = live_setup.spoilers_in(td)
        self.assertTrue(any("SPEC.md" in h for h in hits))


if __name__ == "__main__":
    unittest.main()
