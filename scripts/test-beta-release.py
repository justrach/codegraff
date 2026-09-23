import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

module_path = pathlib.Path(__file__).with_name("beta-release.py")
spec = importlib.util.spec_from_file_location("beta_release", module_path)
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)
tag_spec = importlib.util.spec_from_file_location("release_tag", module_path.with_name("check-release-tag.py"))
release_tag = importlib.util.module_from_spec(tag_spec)
tag_spec.loader.exec_module(release_tag)


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

    def test_stable_and_beta_channels_remain_separate(self):
        self.assertTrue(release_tag.is_stable_tag("v0.0.302"))
        self.assertTrue(release_tag.is_stable_tag("v0.0.302.4"))
        for tag in ("v0.0.302.4-beta.20.1", "v0.0.302-rc.1", "v0.0.302.4.1", "vnext"):
            self.assertFalse(release_tag.is_stable_tag(tag))
        stable_workflow = (module_path.parent.parent / ".github/workflows/release.yml").read_text()
        beta_workflow = (module_path.parent.parent / ".github/workflows/beta-release.yml").read_text()
        self.assertIn('"!v*-*"', stable_workflow)
        self.assertEqual(stable_workflow.count("scripts/check-release-tag.py"), 2)
        self.assertNotIn("install.sh", beta_workflow)
        self.assertIn("--prerelease --latest=false", beta_workflow)

    def test_stale_publication_is_a_clean_skip_but_remote_error_fails(self):
        argv = ["beta-release.py", "guard", "--branch", "release/v0.0.302.4", "--sha", "old"]
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "output"
            with mock.patch.object(sys, "argv", argv), mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
                with mock.patch.object(beta, "remote_heads", return_value={"release/v0.0.302.4": "new"}):
                    beta.main()
                self.assertEqual(output.read_text(), "publish=false\n")
                with mock.patch.object(beta, "remote_heads", side_effect=subprocess.CalledProcessError(1, "git ls-remote")):
                    with self.assertRaises(subprocess.CalledProcessError):
                        beta.main()


if __name__ == "__main__":
    unittest.main()
