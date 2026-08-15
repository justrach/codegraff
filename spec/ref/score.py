"""Executable port of lean-proofs/Graff/Score.lean.

A score is maintained (filed) iff fleet is on, roleOf(label, niche) is a
canonical slot, and the stage carries a signal. HMAC is out of the model.
"""

from __future__ import annotations

from itertools import product
from typing import Literal

Slot = Literal[
    "find",
    "verify",
    "synthesize",
    "sweep",
    "variants",
    "build",
    "transform",
    "scope",
    "implement",
    "review",
    "none",
]
Signal = Literal["unreached", "allFail", "overflow", "clean", "someOk"]
SLOTS: tuple[Slot, ...] = (
    "find",
    "verify",
    "synthesize",
    "sweep",
    "variants",
    "build",
    "transform",
    "scope",
    "implement",
    "review",
    "none",
)
CANONICAL: tuple[Slot, ...] = SLOTS[:-1]
SIGNALS: tuple[Signal, ...] = ("unreached", "allFail", "overflow", "clean", "someOk")
# attempted, ok — the numbers Zig feeds stageScore
SIGNAL_COUNTS: dict[Signal, tuple[int, int]] = {
    "unreached": (0, 0),
    "allFail": (1, 0),
    "overflow": (1, 2),
    "clean": (2, 2),
    "someOk": (3, 2),
}
CUBE = 1210  # 2 × 11 × 11 × 5

# normalizeOutboundScore samples: raw float → millipoints or None
SCALE: tuple[dict, ...] = (
    {"id": "zero", "raw": 0.0, "milli": 0},
    {"id": "half", "raw": 0.5, "milli": 500},
    {"id": "one", "raw": 1.0, "milli": 1000},
    {"id": "fortyThree", "raw": 43.0, "milli": 430},
    {"id": "hundred", "raw": 100.0, "milli": 1000},
    {"id": "neg", "raw": -1.0, "milli": None},
    {"id": "over", "raw": 100.5, "milli": None},
)

TITLES: tuple[tuple[str, Slot], ...] = (
    ("find", "find"),
    ("find security bugs", "find"),
    ("Synthesize the results", "synthesize"),
    ("VERIFY each finding", "verify"),
    ("review the findings", "review"),
    ("transform each file", "transform"),
    ("  - sweep the repo", "sweep"),
    ("ponder", "none"),
    ("code review", "none"),
    ("", "none"),
)


def role_of(label: Slot, niche: Slot) -> Slot:
    return niche if label == "none" else label


def has_signal(sig: Signal) -> bool:
    return sig in ("clean", "someOk")


def files(fleet: bool, label: Slot, niche: Slot, sig: Signal) -> bool:
    return fleet and role_of(label, niche) != "none" and has_signal(sig)


def stage_score(attempted: int, ok: int) -> int | None:
    """Millipoints, or None when the live function returns null."""
    if attempted == 0 or ok == 0 or ok > attempted:
        return None
    return (ok * 1000) // attempted


def all_file_cases() -> list[tuple[bool, Slot, Slot, Signal]]:
    return list(product((False, True), SLOTS, SLOTS, SIGNALS))


def check_properties() -> int:
    n = 0
    for fleet, label, niche, sig in all_file_cases():
        n += 1
        got = files(fleet, label, niche, sig)
        att, ok = SIGNAL_COUNTS[sig]
        signal_ok = stage_score(att, ok) is not None
        want = fleet and role_of(label, niche) != "none" and signal_ok
        if got != want:
            raise ValueError(f"files: fleet={fleet} {label}/{niche} {sig} got={got}")
        if not fleet and got:
            raise ValueError(f"fleet-off-never-files: {label} {sig}")
        if label == "none" and niche == "none" and got:
            raise ValueError(f"uncelled-never-files: {sig}")
        if not has_signal(sig) and got:
            raise ValueError(f"no-signal-never-files: {label} {sig}")
    if n != CUBE:
        raise ValueError(f"score-cube: n={n} want={CUBE}")
    if role_of("none", "transform") != "transform":
        raise ValueError("role-fallback: niche must supply the slot")
    if role_of("review", "find") != "review":
        raise ValueError("role-prefers-label")
    if stage_score(0, 0) is not None or stage_score(1, 0) is not None:
        raise ValueError("stage-score: unreached/all-fail must reject")
    if stage_score(1, 2) is not None:
        raise ValueError("stage-score: ok>attempted must reject")
    if stage_score(2, 2) != 1000 or stage_score(5, 4) != 800:
        raise ValueError("stage-score: clean fraction")
    if len(CANONICAL) != 10:
        raise ValueError(f"ten-slots: {len(CANONICAL)}")
    return n


def payload() -> dict:
    cases = []
    for fleet, label, niche, sig in all_file_cases():
        att, ok = SIGNAL_COUNTS[sig]
        cases.append(
            {
                "id": f"f{int(fleet)}.{label}.{niche}.{sig}",
                "fleet": fleet,
                "label": label,
                "niche": niche,
                "signal": sig,
                "attempted": att,
                "ok": ok,
                "files": files(fleet, label, niche, sig),
                "role": role_of(label, niche),
            }
        )
    return {
        "kernel": "score",
        "version": 1,
        "models": "stageScore+roleOf+normalizeOutboundScore",
        "out": ["HMAC", "providerClass-price", "observe"],
        "slots": list(CANONICAL),
        "cases": cases,
        "scale": [dict(s) for s in SCALE],
        "titles": [{"title": t, "slot": sl} for t, sl in TITLES],
    }
