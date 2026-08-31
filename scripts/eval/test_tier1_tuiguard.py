#!/usr/bin/env python3
"""Integrity tests for the tuiguard pool deadlines (#704)."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock


RUNNER_PATH = Path(__file__).with_name("tier1_tuiguard.py")
SPEC = importlib.util.spec_from_file_location("tier1_tuiguard", RUNNER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {RUNNER_PATH}")
tuiguard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tuiguard)


class DeadlineTests(unittest.TestCase):
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


if __name__ == "__main__":
    raise SystemExit(unittest.main())
