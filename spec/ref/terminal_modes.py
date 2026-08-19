"""Executable port of lean-proofs/Graff/TerminalModes.lean.

Also the semantics behind scripts/tui-pty-guard.py's mode-balance check:
one model gates the fixtures AND the live binary.
"""

from __future__ import annotations

import re
from pathlib import Path

DEFAULT_ON = (7, 25)

MODE_RE = re.compile(r"\x1b\[\?([0-9;]+)([hl])")
KITTY_PUSH_RE = re.compile(r"\x1b\[>[0-9;]*u")
KITTY_POP_RE = re.compile(r"\x1b\[<[0-9;]*u")

# graff's actual sequences (TUI/run.zig enable_seq / TUI/restore.zig seq).
# The Zig conformance test parses the live constants and diffs them against
# the fixture copy of these, so drift in either direction trips.
GRAFF_ENABLE = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m"
GRAFF_RESTORE = "\x1b[?2026l\x1b[r\x1b[>4;0m\x1b[<u\x1b[?7h\x1b[?1006l\x1b[?1003l\x1b[?1000l\x1b[?2004l\x1b[?25h\x1b[?1049l"


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


# Machine state: last-op-wins mode map + kitty depth (floored at 0).
State = tuple[dict[int, bool], int]
KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "terminal_modes.md"


def step(s: State, op: tuple[str, int]) -> State:
    final, depth = s
    kind, n = op
    out = dict(final)
    if kind == "set":
        out[n] = True
    elif kind == "reset":
        out[n] = False
    elif kind == "push":
        return out, depth + 1
    else:
        return out, max(depth - 1, 0)
    return out, depth


def fold(ops: list[tuple[str, int]]) -> State:
    s: State = ({}, 0)
    for op in ops:
        s = step(s, op)
    return s


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
    check_diagram()
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


def project(s: State) -> str:
    final, depth = s
    alt = bool(final.get(1049))
    if depth == 0 and not deviations(final):
        return "Idle"
    if alt and depth >= 1:
        return "Active"
    if alt:
        return "Alt"
    if depth > 0:
        return "Kitty"
    return "Deviant"


def event_label(op: tuple[str, int]) -> str:
    kind, n = op
    if kind in ("push", "pop"):
        return kind
    return f"{kind} {n}"


def walk_ops(start: State, ops: list[tuple[str, int]]) -> list[tuple[State, tuple[str, int], State]]:
    s = start
    out: list[tuple[State, tuple[str, int], State]] = []
    for op in ops:
        t = step(s, op)
        if t != s:
            out.append((s, op, t))
        s = t
    return out


def diagram_edges() -> list[tuple[str, str, str]]:
    found: set[tuple[str, str, str]] = set()
    extra: list[tuple[str, int]] = [
        ("pop", 0),
        ("push", 0),
        ("pop", 0),
        ("set", 1049),
        ("reset", 1049),
        ("set", 2004),
        ("reset", 2004),
    ]
    streams = [parse_ops(GRAFF_ENABLE + GRAFF_RESTORE), extra]
    for ops in streams:
        for s, op, t in walk_ops(({}, 0), ops):
            a, b = project(s), project(t)
            if a == b:
                continue
            found.add((a, event_label(op), b))
    return sorted(found)


def mermaid() -> str:
    lines = ["stateDiagram-v2", "  [*] --> Idle"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: terminal modes\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/TerminalModes.lean`.\n"
        "\n"
        "Process kernel, not a Turing machine: `Op` / `step` is the mode map\n"
        "plus kitty depth. The 14 named sequences are the snapshot. Enable then\n"
        "restore returns to Idle; restore leaves the alt-screen last; pop floors\n"
        "at zero. TUI layout, glyphs, and the font stay never.\n"
        "\n"
        "The diagram is the projection of the live Python `step`. Emit it with\n"
        "`python3 spec/conformance.py --diagram terminal_modes`.\n"
        "\n"
        "```mermaid\n"
        f"{body}\n"
        "```\n"
    )


def write_kernel_md(path: Path = KERNEL_MD) -> Path:
    path.write_text(kernel_md())
    return path


def check_diagram() -> None:
    s: State = ({}, 0)
    for op in parse_ops(GRAFF_ENABLE + GRAFF_RESTORE):
        s = step(s, op)
    if project(s) != "Idle":
        raise ValueError("diagram: enable+restore did not return to Idle")
    if step(({}, 0), ("pop", 0))[1] != 0:
        raise ValueError("diagram: pop from Idle left depth != 0")
    text = mermaid()
    if "Idle --> Alt: set 1049" not in text:
        raise ValueError("diagram: mermaid missing Idle set-1049→Alt")
    if "Alt --> Idle: reset 1049" not in text:
        raise ValueError("diagram: mermaid missing Alt reset-1049→Idle")
    if "Alt --> Active: push" not in text:
        raise ValueError("diagram: mermaid missing Alt push→Active")
    if "Idle --> Active: pop" in text:
        raise ValueError("diagram: mermaid has Idle pop→Active")
