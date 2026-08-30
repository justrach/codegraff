"""Held-out checks for stall-widen."""
import os
import sys

sys.path.insert(0, os.getcwd())
from stall import IDLE_FLOOR_MS, inter_frame_budget_ms  # noqa: E402


def main():
    assert inter_frame_budget_ms(20_000, True, 0) == IDLE_FLOOR_MS
    assert inter_frame_budget_ms(5_000, True, 0) == 5_000
    assert inter_frame_budget_ms(5_000, True, 2) == 5_000
    assert inter_frame_budget_ms(600_000, True, 0) == 150_000
    assert inter_frame_budget_ms(600_000, True, 1) == 300_000
    assert inter_frame_budget_ms(600_000, True, 2) == 600_000
    print("hidden OK")


if __name__ == "__main__":
    main()
