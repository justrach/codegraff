import tempfile
import unittest
from pathlib import Path

from environment import materialize
from grader import grade
from reference import apply_reference
from run import final_reward


class EnvironmentTests(unittest.TestCase):
    def test_baseline_fails_and_reference_passes_across_seeds(self):
        for seed in (1, 469, 9001):
            with self.subTest(seed=seed), tempfile.TemporaryDirectory() as raw:
                workspace = Path(raw)
                materialize(workspace, seed)
                self.assertFalse(grade(workspace, seed)["deterministic_pass"])
                apply_reference(workspace)
                report = grade(workspace, seed)
                self.assertTrue(report["deterministic_pass"], report)

    def test_protected_fixture_tampering_forces_zero(self):
        with tempfile.TemporaryDirectory() as raw:
            workspace = Path(raw)
            materialize(workspace, 469)
            apply_reference(workspace)
            (workspace / "tests/test_api.py").write_text("# easier\n", encoding="utf-8")
            report = grade(workspace, 469)
            self.assertFalse(report["deterministic_pass"])
            self.assertEqual(0.0, report["score"])

    def test_incorrect_solution_cannot_enter_passing_reward_band(self):
        failing = {"deterministic_pass": False, "score": 0.8}
        passing = {"deterministic_pass": True, "score": 0.9}
        fail_reward, _ = final_reward(failing, 1, 1, 1.0)
        pass_reward, _ = final_reward(passing, 1, 1, 0.0)
        self.assertLessEqual(fail_reward, 0.8)
        self.assertGreaterEqual(pass_reward, 0.9)


if __name__ == "__main__":
    unittest.main()
