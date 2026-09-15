"""Deterministic frame-clock coverage for the terminal hover baseline."""
import importlib.util
from pathlib import Path
import unittest

probe_path = Path(__file__).resolve().parents[1] / "test-tui-hover.py"
spec = importlib.util.spec_from_file_location("tui_hover_probe", probe_path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
from ptyharness import Cell


class Frames:
    cols, rows = 40, 6
    canvas, flash = (20, 20, 20), (36, 36, 36)

    def __init__(self, style):
        self.now = 0.0
        self.style = style

    def pump(self, seconds):
        self.now += seconds

    def screen_lines(self):
        return ["", "› Read 1 file" if self.style(self.now) != "missing" else "", "", "", "", ""]

    def cell(self, x, y):
        text = self.screen_lines()[y].ljust(self.cols)
        style = self.style(self.now)
        colored = y == 1 and (style == "uniform" or (style == "flash" and 1 <= x < self.cols - 1))
        return Cell(text[x], bg=self.flash if colored else self.canvas)


class HoverBaselineTests(unittest.TestCase):
    def wait(self, frames, timeout=2.0):
        return probe.wait_for_resting_row(frames, timeout, lambda: frames.now)

    def test_completion_flash_must_end_before_baseline(self):
        frames = Frames(lambda t: "flash" if t < 1.0 else "canvas")
        self.assertEqual(self.wait(frames), 1)
        self.assertGreaterEqual(frames.now, 1.1)
        self.assertLess(frames.now, 1.3)

    def test_one_transitional_canvas_frame_does_not_satisfy_stability(self):
        frames = Frames(lambda t: "canvas" if t < 0.05 or t >= 1.0 else "flash")
        self.assertEqual(self.wait(frames), 1)
        self.assertGreaterEqual(frames.now, 1.1)

    def test_uniform_non_canvas_tint_is_not_a_valid_baseline(self):
        frames = Frames(lambda _: "uniform")
        with self.assertRaisesRegex(TimeoutError, "canvas"):
            self.wait(frames)
        self.assertAlmostEqual(frames.now, 2.0)

    def test_permanent_mixed_background_still_fails(self):
        frames = Frames(lambda _: "flash")
        with self.assertRaisesRegex(TimeoutError, "did not settle"):
            self.wait(frames)
        self.assertAlmostEqual(frames.now, 2.0)

    def test_missing_header_fails_at_the_deadline(self):
        frames = Frames(lambda _: "missing")
        with self.assertRaisesRegex(TimeoutError, "no folded tool summary"):
            self.wait(frames)
        self.assertAlmostEqual(frames.now, 2.0)

    def test_already_settled_row_needs_only_a_stable_frame_interval(self):
        frames = Frames(lambda _: "canvas")
        self.assertEqual(self.wait(frames), 1)
        self.assertAlmostEqual(frames.now, 0.1)
