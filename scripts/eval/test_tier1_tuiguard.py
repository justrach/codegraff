#!/usr/bin/env python3
"""Integrity tests for the tuiguard pool deadlines (#704)."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import mock


RUNNER_PATH = Path(__file__).with_name("tier1_tuiguard.py")
SPEC = importlib.util.spec_from_file_location("tier1_tuiguard", RUNNER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {RUNNER_PATH}")
tuiguard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tuiguard)


class DeadlineTests(unittest.TestCase):
    @mock.patch.dict(os.environ, {"GRAFF_TUIGUARD_PROBE_TIMEOUT": ""})
    def test_probe_timeout_uses_long_list_and_env(self) -> None:
        self.assertEqual(tuiguard.probe_timeout("test-tui-click.py"), 90.0)
        self.assertEqual(tuiguard.probe_timeout("tui-pty-guard.py"), 60.0)
        with mock.patch.dict(os.environ, {"GRAFF_TUIGUARD_PROBE_TIMEOUT": "0.4"}):
            self.assertEqual(tuiguard.probe_timeout("test-tui-click.py"), 0.4)

    def test_parent_budget_is_waves_times_longest_plus_slack(self) -> None:
        names = ("a.py", "b.py", "c.py")
        with mock.patch.object(tuiguard, "probe_timeout", return_value=10.0):
            # 3 probes / 2 workers = 2 waves → 20 + 60
            self.assertEqual(tuiguard.parent_budget(2, names), 80.0)

    def test_run_command_kills_a_wedged_child(self) -> None:
        status, blob, elapsed, timed_out = tuiguard.run_command(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            timeout=0.3,
        )
        self.assertTrue(timed_out)
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 5.0)
        self.assertGreaterEqual(elapsed, 0.25)
        _ = blob

    def test_run_command_kills_the_process_group(self) -> None:
        if not hasattr(os, "fork") or not hasattr(os, "kill"):
            self.skipTest("posix process groups")
        scratch = tempfile.TemporaryDirectory(prefix="tuiguard-pg-")
        self.addCleanup(scratch.cleanup)
        marker = Path(scratch.name) / "pids"
        child = r"""
import os, sys, time
from pathlib import Path
marker = Path(sys.argv[1])
g = os.fork()
if g == 0:
    time.sleep(60)
    os._exit(0)
marker.write_text(f"{os.getpid()}\n{g}\n", encoding="utf-8")
time.sleep(60)
"""
        status, _, elapsed, timed_out = tuiguard.run_command(
            [sys.executable, "-c", child, str(marker)],
            timeout=0.4,
        )
        self.assertTrue(timed_out)
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 5.0)
        time.sleep(0.1)
        pids = [int(x) for x in marker.read_text(encoding="utf-8").split() if x.strip()]
        self.assertEqual(len(pids), 2)
        for pid in pids:
            with self.assertRaises(OSError):
                os.kill(pid, 0)

    def test_run_pool_names_still_running_on_parent_deadline(self) -> None:
        def hang(script: str, binary: str, timeout: float):
            time.sleep(5)
            return script, 0, "", 5.0, False

        with mock.patch.object(tuiguard, "run_probe", side_effect=hang):
            with mock.patch("builtins.print") as printer:
                rc = tuiguard.run_pool(
                    "/nonexistent/graff",
                    probes=("test-tui-hover.py",),
                    jobs=1,
                    parent_seconds=0.2,
                )
        self.assertEqual(rc, 1)
        joined = " ".join(
            str(call.args[0]) for call in printer.call_args_list if call.args
        )
        self.assertIn("still running: test-tui-hover.py", joined)


@unittest.skipUnless(os.name == "posix", "POSIX clipboard wrappers")
class ClipboardTests(unittest.TestCase):
    def clipboard(self, env, command, data=None):
        fixture_dir = Path(env["PATH"].split(os.pathsep)[0])
        executable = shutil.which(command[0], path=env["PATH"])
        self.assertIsNotNone(executable)
        self.assertEqual(Path(executable).parent, fixture_dir)
        return subprocess.run(
            command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, check=True, timeout=5,
        ).stdout

    def test_copy_paste_preserves_exact_bytes(self) -> None:
        payload = b"\x00\xffclipboard\r\nUTF-8: \xe2\x98\x83\n\n"
        with tuiguard.private_clipboard() as env:
            for copy, paste in (
                (["pbcopy"], ["pbpaste"]),
                (["xclip", "-selection", "clipboard"],
                 ["xclip", "-selection", "clipboard", "-o"]),
                (["pbcopy"], ["xclip", "-selection", "clipboard", "-o"]),
                (["xclip", "-selection", "clipboard"], ["pbpaste"]),
            ):
                for data in (payload, b""):
                    with self.subTest(copy=copy, paste=paste, data=data):
                        self.clipboard(env, copy, data)
                        self.assertEqual(self.clipboard(env, paste), data)

    def test_xclip_quiet_stdin_reads_instead_of_blocking(self) -> None:
        # Hover (and any probe that only finds xclip) invokes it with a quiet
        # stdin. Treat that as a read; blocking on stdin hung the paint sweep.
        with tuiguard.private_clipboard() as env:
            self.clipboard(env, ["pbcopy"], b"seeded")
            read_end, write_end = os.pipe()
            try:
                started = time.monotonic()
                out = subprocess.run(
                    ["xclip", "-selection", "clipboard"],
                    stdin=read_end,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                    check=True,
                    timeout=2,
                ).stdout
                self.assertLess(time.monotonic() - started, 1.0)
                self.assertEqual(out, b"seeded")
            finally:
                os.close(read_end)
                os.close(write_end)

    def test_concurrent_contexts_do_not_interfere(self) -> None:
        barrier = Barrier(2)

        def roundtrip(payload):
            with tuiguard.private_clipboard() as env:
                self.clipboard(env, ["pbcopy"], payload)
                barrier.wait(timeout=10)
                self.assertEqual(self.clipboard(env, ["pbpaste"]), payload)
                return env["PATH"]

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(roundtrip, data) for data in (b"first", b"second")]
            paths = [future.result(timeout=20) for future in futures]
        self.assertNotEqual(*paths)

    def test_context_cleanup_and_process_path_unchanged(self) -> None:
        original_path = os.environ.get("PATH")
        for exceptional in (False, True):
            with self.subTest(exceptional=exceptional):
                try:
                    with tuiguard.private_clipboard() as env:
                        fixture_dir = Path(env["PATH"].split(os.pathsep)[0])
                        self.assertTrue(fixture_dir.is_dir())
                        self.assertEqual(os.environ.get("PATH"), original_path)
                        self.clipboard(env, ["pbcopy"], b"cleanup")
                        if exceptional:
                            raise RuntimeError("context exit")
                except RuntimeError as exc:
                    self.assertEqual(str(exc), "context exit")
                self.assertFalse(fixture_dir.exists())
                self.assertEqual(os.environ.get("PATH"), original_path)

    def test_nested_run_probe_environments_remain_separate(self) -> None:
        original_path = os.environ.get("PATH")
        environments = []

        def run_command(argv, timeout, *, env):
            environments.append(env)
            payload = Path(argv[1]).name.encode()
            self.clipboard(env, ["pbcopy"], payload)
            if len(environments) == 1:
                tuiguard.run_probe("inner.py", "/nonexistent/graff", timeout)
                self.assertIsNot(env, environments[1])
                self.assertNotEqual(env["PATH"], environments[1]["PATH"])
            self.assertEqual(self.clipboard(env, ["pbpaste"]), payload)
            self.assertEqual(os.environ.get("PATH"), original_path)
            return 0, "", 0.0, False

        with mock.patch.object(tuiguard, "run_command", side_effect=run_command):
            tuiguard.run_probe("outer.py", "/nonexistent/graff", 1.0)
        self.assertEqual(len(environments), 2)
        for env in environments:
            self.assertFalse(Path(env["PATH"].split(os.pathsep)[0]).exists())
        self.assertEqual(os.environ.get("PATH"), original_path)

    def test_parallel_run_probe_environments_remain_separate(self) -> None:
        original_path = os.environ.get("PATH")
        barrier = Barrier(2)

        def run_command(argv, timeout, *, env):
            payload = Path(argv[1]).name.encode()
            self.clipboard(env, ["pbcopy"], payload)
            barrier.wait(timeout=10)
            self.assertEqual(self.clipboard(env, ["pbpaste"]), payload)
            self.assertEqual(os.environ.get("PATH"), original_path)
            return 0, env["PATH"], 0.0, False

        with mock.patch.object(tuiguard, "run_command", side_effect=run_command):
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [
                    pool.submit(tuiguard.run_probe, name, "/nonexistent/graff", 1.0)
                    for name in ("first.py", "second.py")
                ]
                results = [future.result(timeout=20) for future in futures]
        self.assertNotEqual(results[0][2], results[1][2])
        for result in results:
            self.assertFalse(Path(result[2].split(os.pathsep)[0]).exists())
        self.assertEqual(os.environ.get("PATH"), original_path)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
