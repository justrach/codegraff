"""Executable port of lean-proofs/Graff/TerminalModes.lean.

Also the semantics behind scripts/tui-pty-guard.py's mode-balance check:
one model gates the fixtures AND the live binary.
"""

from __future__ import annotations

import re

DEFAULT_ON = (7, 25)

MODE_RE = re.compile(r"\x1b\[\?([0-9;]+)([hl])")
KITTY_PUSH_RE = re.compile(r"\x1b\[>[0-9;]*u")
KITTY_POP_RE = re.compile(r"\x1b\[<[0-9;]*u")

# graff's actual sequences (TUI/run.zig enable_seq / TUI/restore.zig seq).
# The Zig conformance test parses the live constants and diffs them against
# the fixture copy of these, so drift in either direction trips.
GRAFF_ENABLE = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m"
GRAFF_RESTORE = "\x1b[?2026l\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l"


def parse_ops(stream: str) -> list[tuple[str, int]]:
    """Byte stream -> ordered op list: (set|reset, n) | (push|pop, 0)."""
    ops: list[tuple[str, int]] = []
    events = []
    for m in MODE_RE.finditer(stream):
        for num in m.group(1).split(";"):
            events.append((m.start(), "set" if m.group(2) == "h" else "reset", int(num)))
    for m in KITTY_PUSH_RE.finditer(stream):
        events.append((m.start(), "push", 0))
    for m in KITTY_POP_RE.finditer(stream):
        events.append((m.start(), "pop", 0))
    for _, kind, n in sorted(events):
        ops.append((kind, n))
    return ops


def fold(ops: list[tuple[str, int]]) -> tuple[dict[int, bool], int]:
    final: dict[int, bool] = {}
    depth = 0
    for kind, n in ops:
        if kind == "set":
            final[n] = True
        elif kind == "reset":
            final[n] = False
        elif kind == "push":
            depth += 1
        else:
            depth = max(depth - 1, 0)  # grok-build's floor
    return final, depth


def deviations(final: dict[int, bool]) -> list[int]:
    return sorted(n for n, v in final.items() if v != (n in DEFAULT_ON))


def balanced(ops: list[tuple[str, int]]) -> bool:
    final, depth = fold(ops)
    return not deviations(final) and depth == 0


def restore_ops(ops: list[tuple[str, int]]) -> list[tuple[str, int]]:
    final, depth = fold(ops)
    devs = deviations(final)
    flips = [("set" if n in DEFAULT_ON else "reset", n) for n in devs if n != 1049]
    alt = [("reset", 1049)] if 1049 in devs else []
    return [("pop", 0)] * depth + flips + alt


SEQUENCES: tuple[tuple[str, str], ...] = (
    ("empty", ""),
    ("graff-enable", GRAFF_ENABLE),
    ("graff-lifecycle", GRAFF_ENABLE + GRAFF_RESTORE),
    ("alt-only", "\x1b[?1049h"),
    ("paste-only", "\x1b[?2004h"),
    ("paste-balanced", "\x1b[?2004h\x1b[?2004l"),
    ("cursor-hidden", "\x1b[?25l"),
    ("autowrap-off", "\x1b[?7l"),
    ("kitty-unpopped", "\x1b[>1u"),
    ("kitty-overpop", "\x1b[<u\x1b[<u\x1b[>1u"),
    ("multi-num", "\x1b[?1000;1006h\x1b[?1000l"),
    ("relatch", "\x1b[?1049h\x1b[?1049l\x1b[?1049h"),
    ("default-noise", "\x1b[?2026l\x1b[?25h\x1b[?7h"),
    ("mouse-partial", "\x1b[?1000h\x1b[?1003h\x1b[?1003l"),
)


def check_properties() -> int:
    n = 0
    for name, stream in SEQUENCES:
        n += 1
        ops = parse_ops(stream)
        # The generated restore always balances any reachable state.
        if not balanced(ops + restore_ops(ops)):
            raise ValueError(f"restore does not balance {name!r}")
        # Restore of a restored stream is empty (byte transparency).
        if restore_ops(ops + restore_ops(ops)):
            raise ValueError(f"restore not idempotent for {name!r}")
    # graff's committed restore balances graff's committed enable...
    if not balanced(parse_ops(GRAFF_ENABLE + GRAFF_RESTORE)):
        raise ValueError("graff lifecycle unbalanced")
    # ...and its restore leaves the alt-screen LAST.
    last_mode = list(MODE_RE.finditer(GRAFF_RESTORE))[-1]
    if last_mode.group(1) != "1049" or last_mode.group(2) != "l":
        raise ValueError("graff restore does not end with the alt-screen leave")
    return n


def payload() -> dict:
    rows = []
    for name, stream in SEQUENCES:
        ops = parse_ops(stream)
        final, depth = fold(ops)
        rows.append({
            "name": name,
            "stream": stream,
            "deviations": deviations(final),
            "depth": depth,
            "balanced": balanced(ops),
        })
    return {
        "kernel": "terminal_modes",
        "graff_enable": GRAFF_ENABLE,
        "graff_restore": GRAFF_RESTORE,
        "cells": rows,
    }
