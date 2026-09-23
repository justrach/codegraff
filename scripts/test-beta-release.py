import importlib.util
import pathlib
import unittest

module_path = pathlib.Path(__file__).with_name("beta-release.py")
spec = importlib.util.spec_from_file_location("beta_release", module_path)
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)


class BetaReleaseTests(unittest.TestCase):
    def test_latest_branch_uses_numeric_three_and_four_part_order(self):
        heads = {
            "release/v0.0.302": "a",
            "release/v0.0.302.4": "b",
            "release/v0.0.302.10": "c",
            "release/v0.0.303": "d",
        }
        self.assertEqual(beta.version_key("release/v0.0.302"), (0, 0, 302, 0))
        self.assertGreater(beta.version_key("release/v0.0.302.10"), beta.version_key("release/v0.0.302.4"))
        self.assertFalse(beta.current_beta("release/v0.0.302.10", "c", heads))
        self.assertTrue(beta.current_beta("release/v0.0.303", "d", heads))

    def test_stale_branch_or_sha_cannot_publish(self):
        heads = {"release/v0.0.302.4": "new"}
        self.assertFalse(beta.current_beta("release/v0.0.302.4", "old", heads))
        self.assertFalse(beta.current_beta("release/v0.0.302.3", "old", heads))
        self.assertIsNone(beta.plan("release/v0.0.302.4", "old", 20, 1, heads))

    def test_run_attempts_get_distinct_beta_versions(self):
        heads = {"release/v0.0.302.4": "sha"}
        first = beta.plan("release/v0.0.302.4", "sha", 20, 1, heads)
        second = beta.plan("release/v0.0.302.4", "sha", 20, 2, heads)
        third = beta.plan("release/v0.0.302.4", "sha", 21, 1, heads)
        self.assertEqual(first, {"version": "0.0.302.4-beta.20.1", "tag": "v0.0.302.4-beta.20.1"})
        self.assertLess(first["version"], second["version"])
        self.assertNotEqual(second["tag"], third["tag"])
        with self.assertRaises(ValueError):
            beta.plan("release/v0.0.302.4", "sha", 20, 0, heads)

    def test_invalid_release_branch_is_rejected(self):
        for branch in ("main", "release/v0.0.302.4.1", "release/v0.0.302-beta.1", "release/vx.y.z"):
            self.assertIsNone(beta.version_key(branch))
            with self.assertRaises(ValueError):
                beta.current_beta(branch, "sha", {"release/v0.0.302.4": "sha"})


if __name__ == "__main__":
    unittest.main()
