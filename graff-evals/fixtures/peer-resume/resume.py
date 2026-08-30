"""Peer-channel resume — incomplete. Fix the SPEC.md contract."""

ROOM = ["[peer] alice: leftover", "[peer] bob: also leftover"]


def snapshot(cursor, inbox):
    return {"cursor": cursor, "inbox": list(inbox)}


def resume(snap):
    # BUG: replays the room into history (ADR 0014).
    return {
        "cursor": 0,
        "inbox": [],
        "history": list(ROOM),
    }
