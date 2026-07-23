#!/usr/bin/env python3
"""Focused integrity tests for the pinned CI Zig installer."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


INSTALLER_PATH = Path(__file__).with_name("install-zig-ci.py")
SPEC = importlib.util.spec_from_file_location("install_zig_ci", INSTALLER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {INSTALLER_PATH}")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class ToolchainIntegrityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory(prefix="codegraff-installer-test-")
        self.root = Path(self.scratch.name) / "toolchain"
        (self.root / "lib").mkdir(parents=True)
        (self.root / "lib" / "std.zig").write_bytes(b"pub const answer: u8 = 42;\n")
        self.binary = self.root / "zig"
        self.binary.write_text(
            f"#!/bin/sh\nprintf '%s\\n' '{installer.PINNED_VERSION}'\n",
            encoding="utf-8",
        )
        self.binary.chmod(0o755)
        (self.root / "std-link").symlink_to("lib/std.zig")
        self.binary_sha = installer.sha256(self.binary)
        self.tree_sha = installer.tree_sha256(self.root)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def validate(self) -> tuple[bool, str]:
        return installer.validate_toolchain(
            self.root,
            "Linux",
            installer.PINNED_VERSION,
            self.binary_sha,
            self.tree_sha,
        )

    def test_exact_tree_is_accepted(self) -> None:
        self.assertEqual(self.validate(), (True, installer.PINNED_VERSION))

    def test_modified_file_is_rejected(self) -> None:
        (self.root / "lib" / "std.zig").write_bytes(b"tampered\n")
        valid, reason = self.validate()
        self.assertFalse(valid)
        self.assertIn("tree SHA-256 mismatch", reason)

    def test_added_file_is_rejected(self) -> None:
        (self.root / "unexpected").write_bytes(b"extra")
        valid, reason = self.validate()
        self.assertFalse(valid)
        self.assertIn("tree SHA-256 mismatch", reason)

    def test_retargeted_symlink_is_rejected(self) -> None:
        (self.root / "std-link").unlink()
        (self.root / "std-link").symlink_to("zig")
        valid, reason = self.validate()
        self.assertFalse(valid)
        self.assertIn("tree SHA-256 mismatch", reason)

    def test_binary_tamper_is_rejected_without_tree_digest(self) -> None:
        self.binary.write_bytes(b"tampered binary\n")
        valid, reason = installer.validate_toolchain(
            self.root,
            "Linux",
            installer.PINNED_VERSION,
            self.binary_sha,
            None,
        )
        self.assertFalse(valid)
        self.assertIn("binary failed", reason)

    def test_invalid_cache_recovers_from_verified_archive(self) -> None:
        runner_temp = Path(self.scratch.name)
        archive_dir = runner_temp / "codegraff-zig-archives"
        archive_dir.mkdir()
        filename_template = "zig-x86_64-linux-{version}.tar.xz"
        filename = filename_template.format(version=installer.PINNED_VERSION)
        archive = archive_dir / filename
        with tarfile.open(archive, "w:xz") as bundle:
            bundle.add(self.root, arcname=f"zig-x86_64-linux-{installer.PINNED_VERSION}")

        install_dir = runner_temp / f"codegraff-zig-{installer.PINNED_VERSION}"
        shutil.copytree(self.root, install_dir, symlinks=True)
        (install_dir / "lib" / "std.zig").write_bytes(b"tampered cache\n")

        workspace = runner_temp / "workspace"
        workspace.mkdir()
        github_path = runner_temp / "github-path"
        github_env = runner_temp / "github-env"
        fake_asset = (
            filename_template,
            installer.sha256(archive),
            self.binary_sha,
            self.tree_sha,
        )
        environment = {
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_PATH": str(github_path),
            "GITHUB_ENV": str(github_env),
            "GITHUB_WORKSPACE": str(workspace),
        }
        with (
            mock.patch.dict(installer.ASSETS, {("Linux", "x86_64"): fake_asset}, clear=True),
            mock.patch.dict(os.environ, environment),
            mock.patch.object(installer.platform, "system", return_value="Linux"),
            mock.patch.object(installer.platform, "machine", return_value="x86_64"),
            mock.patch.object(sys, "argv", [str(INSTALLER_PATH)]),
        ):
            self.assertEqual(installer.main(), 0)

        valid, reason = installer.validate_toolchain(
            install_dir,
            "Linux",
            installer.PINNED_VERSION,
            self.binary_sha,
            self.tree_sha,
        )
        self.assertTrue(valid, reason)
        self.assertIn(str(install_dir), github_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
