"""Stall user-notice — incomplete. Fix the SPEC.md contract."""
GIVE_UP = "⚠ stall — giving up"


def stall_notice(reconnects_left):
    # BUG: warn on every stall, including silent reconnects.
    return "⚠ stall — reconnecting"
