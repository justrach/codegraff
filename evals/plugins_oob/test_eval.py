#!/usr/bin/env python3
"""Unittest wrapper so the plugin inspect eval is a normal `python3 -m unittest`."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from run import (
    CURSOR_HASH,
    assert_mcp_merged,
    assert_mcp_opt_out,
    assert_plugins_named,
    default_graff,
    seed_home,
    self_test,
)


class PluginOobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.graff = os.environ.get("GRAFF", default_graff())
        if not Path(cls.graff).exists():
            raise unittest.SkipTest(f"{cls.graff} missing — run `zig build`")

    def test_self_test_passes(self) -> None:
        self_test(self.graff)

    def test_seeded_home_is_enough_without_the_binary(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            seed_home(home)
            self.assertTrue(
                (home / ".cursor/plugins/cache/cursor-public/evalfix" / CURSOR_HASH / ".cursor-plugin/plugin.json").is_file()
            )
            self.assertIn("eval-gmail", (home / ".cursor/plugins/cache/cursor-public/evalfix" / CURSOR_HASH / ".cursor-plugin/plugin.json").read_text())
            self.assertIn("installPath", (home / ".cursor/plugins/installed_plugins.json").read_text())
            self.assertIn("graff-wins", (home / ".codegraff/mcp.json").read_text())

    def test_assertions_reject_the_wrong_listing(self) -> None:
        good = (
            "6 MCP server(s):\n"
            "  eval-gmail: /bin/false\n"
            "  eval-claude: /bin/false\n"
            "  eval-inline: /home/demo/missing-bin\n"
            "  from-cursor: /bin/false\n"
            "  from-graff: /bin/true  (global)\n"
            "  shared: /bin/true graff-wins  (global)\n"
        )
        assert_mcp_merged(good)
        with self.assertRaises(SystemExit):
            assert_mcp_merged(good.replace("graff-wins", "plugin-loses"))
        opted = (
            "2 MCP server(s):\n"
            "  from-graff: /bin/true  (global)\n"
            "  shared: /bin/true graff-wins  (global)\n"
        )
        assert_mcp_opt_out(opted)
        with self.assertRaises(SystemExit):
            assert_mcp_opt_out(good)
        plugins = (
            "2 plugin(s) (in-place, Claude layout, not copied):\n"
            f"  eval-gmail  [cursor/user] skills mcp  /home/{CURSOR_HASH}\n"
            "  eval-claude  [claude/user] skills commands mcp  /home/demo\n"
        )
        assert_plugins_named(plugins)
        with self.assertRaises(SystemExit):
            assert_plugins_named(f"{CURSOR_HASH}  [cursor/user] mcp\n")


if __name__ == "__main__":
    unittest.main()
