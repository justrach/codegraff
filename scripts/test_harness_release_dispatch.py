import importlib.util
from pathlib import Path
import unittest


path = Path(__file__).with_name("harness-release-dispatch.py")
spec = importlib.util.spec_from_file_location("harness_release_dispatch", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleasePayloadTests(unittest.TestCase):
    sha = "a" * 40

    def release(self, tag, prerelease, names):
        return {
            "tag_name": tag,
            "draft": False,
            "published_at": "2026-09-24T00:00:00Z",
            "prerelease": prerelease,
            "target_commitish": self.sha,
            "assets": [{"name": name} for name in names],
        }

    def test_beta_is_tied_to_branch_and_cli_assets(self):
        tag = "v0.0.302.4-beta.19.1"
        release = self.release(tag, True, module.CLI_ASSETS)
        payload = module.release_payload("beta", tag, self.sha, release, "release/v0.0.302.4")
        self.assertEqual(payload["branch"], "release/v0.0.302.4")
        with self.assertRaises(ValueError):
            module.release_payload("beta", tag, self.sha, release, "release/v0.0.302.3")
        release["assets"] = []
        with self.assertRaises(ValueError):
            module.release_payload("beta", tag, self.sha, release, "release/v0.0.302.4")

    def test_stable_requires_published_desktop_assets(self):
        tag = "v0.0.302.4"
        release = self.release(tag, False, module.CLI_ASSETS | module.SIGNED_DESKTOP_ASSETS)
        self.assertEqual(module.release_payload("stable", tag, self.sha, release)["channel"], "stable")
        release["draft"] = True
        with self.assertRaises(ValueError):
            module.release_payload("stable", tag, self.sha, release)
        release["draft"] = False
        release["assets"] = [{"name": name} for name in module.CLI_ASSETS]
        with self.assertRaises(ValueError):
            module.release_payload("stable", tag, self.sha, release)


if __name__ == "__main__":
    unittest.main()
