"""Stall-budget arithmetic — incomplete. Fix the SPEC.md contract."""
IDLE_DIVISOR = 4
IDLE_FLOOR_MS = 15_000
HEAD_CEILING_MS = 45_000


def inter_frame_budget_ms(base_ms, tokens_flowing, reconnects=0):
    if not tokens_flowing:
        return min(base_ms, HEAD_CEILING_MS)
    # BUG: reconnects ignored — every attempt stays at base/4 (30s at default).
    _ = reconnects
    return min(base_ms, max(IDLE_FLOOR_MS, base_ms // IDLE_DIVISOR))
