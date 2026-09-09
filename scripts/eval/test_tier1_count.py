#!/usr/bin/env python3
"""#794: the suite ratchet counts skipped Zig tests with passed ones."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


MODULE = Path(__file__).with_name("tier1_test_binary.py")
SPEC = importlib.util.spec_from_file_location("tier1_test_binary", MODULE)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {MODULE}")
binary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binary)


class SuiteCountTests(unittest.TestCase):
    def test_skipped_tests_are_in_the_suite(self) -> None:
        text = (
            "Build Summary: 6/6 steps succeeded; 2079/2080 tests passed (1 skipped)\n"
            "+- run test 2079 pass, 1 skip (2080 total)\n"
        )
        self.assertEqual(2080, binary.suite_count_from_summary(text))

    def test_passed_only_summary_uses_the_total(self) -> None:
        text = "Build Summary: 6/6 steps succeeded; 2072/2072 tests passed\n"
        self.assertEqual(2072, binary.suite_count_from_summary(text))

    def test_artifact_mixed_line_adds_skips(self) -> None:
        self.assertEqual(2080, binary.suite_count_from_summary("2079 passed; 1 skipped; 0 failed.\n"))
        self.assertEqual(2072, binary.suite_count_from_summary("All 2072 tests passed.\n"))

    def test_cached_steps_only_summary_is_empty(self) -> None:
        text = "Build Summary: 4/4 steps succeeded\n"
        self.assertIsNone(binary.suite_count_from_summary(text))

    def test_passed_count_alone_is_not_the_suite(self) -> None:
        # The old sed took 2079 from 2079/2080. That is the bug.
        text = "Build Summary: 6/6 steps succeeded; 2079/2080 tests passed (1 skipped)\n"
        self.assertNotEqual(2079, binary.suite_count_from_summary(text))


if __name__ == "__main__":
    unittest.main()
