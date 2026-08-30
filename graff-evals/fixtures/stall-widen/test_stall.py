from stall import HEAD_CEILING_MS, inter_frame_budget_ms

BASE = 120_000


def test_head_ceiling_not_widened():
    assert inter_frame_budget_ms(BASE, False, 0) == HEAD_CEILING_MS
    assert inter_frame_budget_ms(BASE, False, 2) == HEAD_CEILING_MS


def test_between_lines_widens():
    assert inter_frame_budget_ms(BASE, True, 0) == 30_000
    assert inter_frame_budget_ms(BASE, True, 1) == 60_000
    assert inter_frame_budget_ms(BASE, True, 2) == BASE
    assert inter_frame_budget_ms(BASE, True, 9) == BASE


if __name__ == "__main__":
    test_head_ceiling_not_widened()
    test_between_lines_widens()
    print("OK")
