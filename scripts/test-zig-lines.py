#!/usr/bin/env python3
"""Integrity tests for the first-party Zig source-size guard."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("check-zig-lines.sh")


class ZigLineGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(prefix="codegraff-line-guard-")
        self.root = Path(self.scratch.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "line-guard@example.invalid"],
            cwd=self.root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Line Guard"],
            cwd=self.root,
            check=True,
        )

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def write_zig(self, relative: str, lines: int) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("const line_guard_probe = 1;\n" * lines, encoding="utf-8")
        return path

    def run_guard(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "scripts/check-zig-lines.sh"],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_exactly_600_lines_passes(self) -> None:
        self.write_zig("src/exact.zig", 600)
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("at most 600 lines", completed.stdout)

    def test_tracked_601_line_file_fails_with_path_and_count(self) -> None:
        path = self.write_zig("src/tracked.zig", 601)
        subprocess.run(["git", "add", str(path.relative_to(self.root))], cwd=self.root, check=True)
        completed = self.run_guard()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("src/tracked.zig (601)", completed.stderr)

    def test_untracked_601_line_file_also_fails(self) -> None:
        self.write_zig("src/new-module.zig", 601)
        completed = self.run_guard()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("src/new-module.zig (601)", completed.stderr)

    def test_vendored_sources_are_exempt(self) -> None:
        self.write_zig("vendor/upstream/large.zig", 900)
        completed = self.run_guard()
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
