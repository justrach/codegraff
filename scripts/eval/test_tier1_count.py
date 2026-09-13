#!/usr/bin/env python3
"""#794: the suite ratchet counts skipped Zig tests with passed ones."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


MODULE = Path(__file__).with_name("tier1_test_binary.py")
SPEC = importlib.util.spec_from_file_location("tier1_test_binary", MODULE)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {MODULE}")
binary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(binary)


class SuiteCountTests(unittest.TestCase):
    def test_pooled_and_unicode_names_are_reachable(self) -> None:
        names = {"first — α": "one.zig", "second": "two.zig", "missing": "three.zig"}
        blob = "one.test.first — αtwo.test.second\0merely mentions missing\0".encode()
        self.assertEqual({"first — α", "second"}, binary.names_in_blob(blob, names))

    def test_plain_and_prefixed_c_strings_remain_reachable(self) -> None:
        self.assertEqual({"first", "second"}, binary.names_in_blob(b"first\0test.second\0", {"first", "second", "absent"}))

    def test_many_missing_names_do_not_need_a_binary_wide_alternation(self) -> None:
        names = {f"case {i}": f"fixture{i}.zig" for i in range(1000)}
        blob = b"unrelated printable binary data " * 200000 + b"fixture987.test.case 987\0"
        self.assertEqual({"case 987"}, binary.names_in_blob(blob, names))

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


class ArtifactNameTests(unittest.TestCase):
    def test_empty_and_unrelated_binary_data_have_no_names(self) -> None:
        names = {"known heading": "owner.zig"}
        for blob in (b"", b" \n\t", b"noise known heading noise\0other.test.known heading\0"):
            with self.subTest(blob=blob):
                self.assertEqual(set(), binary.names_in_blob(blob, names))

    def test_exact_and_pooled_names_keep_unicode_and_prefixes(self) -> None:
        names = {name: "owner.zig" for name in ("bare", "short", "shorter", 'résumé — "quoted"')}
        blob = (
            b"test.bare\0owner.test.shortowner.test.shorter\0"
            + 'owner.test.résumé — "quoted"'.encode("utf-8")
            + b"\0"
        )
        self.assertEqual(set(names), binary.names_in_blob(blob, names))
        # A longer test name does not also prove its shorter prefix exists.
        self.assertEqual({"shorter"}, binary.names_in_blob(b"owner.test.shorter\0", names))

    def test_absent_names_in_large_unrelated_regions_stay_absent(self) -> None:
        names = {f"case {i}": "owner.zig" for i in range(1000)}
        noise = b"ordinary binary data " * 50_000
        blob = noise + b"\0owner.test.case 10owner.test.case 999\0" + noise
        self.assertEqual({"case 10", "case 999"}, binary.names_in_blob(blob, names))

    def test_selection_ignores_newer_filtered_artifact(self) -> None:
        names = {"first": "owner.zig", "second": "owner.zig"}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            filtered, full = root / "filtered", root / "full"
            filtered.write_bytes(b"owner.test.first\0")
            full.write_bytes(b"owner.test.firstowner.test.second\0")
            with mock.patch.object(binary, "candidates", return_value=[filtered, full]):
                chosen = binary.select([], names)
                self.assertEqual(full, chosen.path)
                self.assertFalse(chosen.missing)
                self.assertFalse(chosen.was_newest)
                self.assertEqual(2, chosen.considered)
                self.assertEqual(filtered, binary.select(["first"], names).path)


if __name__ == "__main__":
    unittest.main()
