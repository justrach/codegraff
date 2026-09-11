import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pty_cleanup import close_pty
from ptyharness import PtyHarness


class CleanupTests(unittest.TestCase):
    def test_releases_both_endpoints_before_reaping(self):
        closed = []
        harness = PtyHarness.__new__(PtyHarness)
        harness._closed = False
        harness.exit_status = None
        harness.pid, harness.master, harness.slave = 42, 10, 11
        polls = 0

        def wait(pid, flags):
            nonlocal polls
            polls += 1
            if polls == 1:
                return 0, 0  # Initial liveness check, before teardown.
            self.assertEqual(closed, [10, 11])
            self.assertEqual(flags, os.WNOHANG)
            return pid, 9

        with patch('pty_cleanup.os.kill'), patch('pty_cleanup.os.close', side_effect=closed.append), patch('pty_cleanup.os.waitpid', side_effect=wait):
            harness.close()
            self.assertEqual(harness.exit_status, 9)
            self.assertTrue(harness._closed)

    def test_wedged_child_fails_within_deadline(self):
        with patch('pty_cleanup.os.kill'), patch('pty_cleanup.os.close'), patch('pty_cleanup.os.waitpid', return_value=(0, 0)), patch('pty_cleanup.time.monotonic', side_effect=[0, 1, 4]), patch('pty_cleanup.time.sleep'):
            with self.assertRaisesRegex(TimeoutError, 'PTY child'):
                close_pty(42, (10, 11), timeout=3)

    def test_reaped_child_only_closes_descriptors(self):
        with patch('pty_cleanup.os.kill') as kill, patch('pty_cleanup.os.close') as close, patch('pty_cleanup.os.waitpid') as wait:
            close_pty(None, (10, 11))
            self.assertEqual(close.call_count, 2)
            kill.assert_not_called()
            wait.assert_not_called()


if __name__ == '__main__':
    unittest.main()
