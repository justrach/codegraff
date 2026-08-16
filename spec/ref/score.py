"""Executable port of lean-proofs/Graff/Score.lean.

A score is maintained (filed) iff fleet is on, roleOf(label, niche) is a
canonical slot, and the stage carries a signal. HMAC is out of the model.
stageScore is the same function; the Signal cube is just its five counts.
providerClass needles are in; the price fallback is out (tier=unknown).
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
Tier = Literal["frontier", "mid", "small", "unknown"]
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
FILED = 240  # 1 × 120 celled pairs × 2 live signals

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
    ("安全 review", "none"),
)

# Most-specific first; matches scoring.providerClass needles.
NEEDLES: tuple[tuple[str, Tier], ...] = (
    ("haiku", "small"),
    ("flash", "small"),
    ("-mini", "small"),
    ("lite", "small"),
    ("nano", "small"),
    ("terra", "mid"),
    ("luna", "small"),
    ("opus", "frontier"),
    ("gpt-5", "frontier"),
    ("deepseek-v4", "frontier"),
    ("grok-4", "frontier"),
    ("glm-5", "frontier"),
    ("kimi-k2", "frontier"),
    ("minimax-m", "frontier"),
    ("mimo-v2.5-pro", "frontier"),
    ("fugu", "frontier"),
    ("gemini-3", "frontier"),
    ("sonnet", "mid"),
)

# id, expected needle tier (unknown = price fallback, out of the cube)
MODELS: tuple[tuple[str, Tier], ...] = (
    ("claude-opus-4-8", "frontier"),
    ("gpt-5.5", "frontier"),
    ("gpt-5.6-sol", "frontier"),
    ("gpt-5.6-terra", "mid"),
    ("gpt-5.6-luna", "small"),
    ("deepseek-v4-pro", "frontier"),
    ("grok-4.3", "frontier"),
    ("claude-haiku-4-5", "small"),
    ("gemini-3-flash", "small"),
    ("claude-sonnet-4-6", "mid"),
    ("some-unknown-model", "unknown"),
    ("grok-build", "unknown"),
    ("mimo-v2.5", "unknown"),
    ("minimax-m3", "frontier"),
    ("deepseek-v4-flash", "small"),
    ("gemini-3", "frontier"),
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


def needle_tier(model: str) -> Tier | None:
    low = model.lower()
    for needle, tier in NEEDLES:
        if needle in low:
            return tier
    return None


def class_of(model: str) -> Tier:
    return needle_tier(model) or "unknown"


def all_file_cases() -> list[tuple[bool, Slot, Slot, Signal]]:
    return list(product((False, True), SLOTS, SLOTS, SIGNALS))


def check_properties() -> int:
    n = 0
    filed = 0
    for fleet, label, niche, sig in all_file_cases():
        n += 1
        got = files(fleet, label, niche, sig)
        att, ok = SIGNAL_COUNTS[sig]
        signal_ok = stage_score(att, ok) is not None
        want = fleet and role_of(label, niche) != "none" and signal_ok
        if got != want:
            raise ValueError(f"files: fleet={fleet} {label}/{niche} {sig} got={got}")
        if got:
            filed += 1
        if not fleet and got:
            raise ValueError(f"fleet-off-never-files: {label} {sig}")
        if label == "none" and niche == "none" and got:
            raise ValueError(f"uncelled-never-files: {sig}")
        if not has_signal(sig) and got:
            raise ValueError(f"no-signal-never-files: {label} {sig}")
        if got and role_of(label, niche) == "none":
            raise ValueError(f"filed-not-celled: {label}/{niche} {sig}")
        if has_signal(sig) != signal_ok:
            raise ValueError(f"signal-is-stageScore: {sig} has={has_signal(sig)} stage={signal_ok}")
    if n != CUBE:
        raise ValueError(f"score-cube: n={n} want={CUBE}")
    if filed != FILED:
        raise ValueError(f"filed-count: filed={filed} want={FILED}")
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
    if len(TITLES) != 11:
        raise ValueError(f"title-cube: {len(TITLES)}")
    if any(slot == "find" for title, slot in TITLES if title == "review the findings"):
        raise ValueError("first-word-not-substring: review the findings must stay review")
    if any(slot != "none" for title, slot in TITLES if title in ("code review", "安全 review")):
        raise ValueError("off-vocab-titles-uncelled")
    if len(MODELS) != 16:
        raise ValueError(f"class-cube: {len(MODELS)}")
    for mid, want in MODELS:
        got = class_of(mid)
        if got != want:
            raise ValueError(f"classOf: {mid} got={got} want={want}")
        if want == "unknown" and needle_tier(mid) is not None:
            raise ValueError(f"fallback-unknown: {mid} hit a needle")
        if want != "unknown" and needle_tier(mid) is None:
            raise ValueError(f"needle-models-known: {mid} missed")
    if class_of("gemini-3-flash") != "small":
        raise ValueError("flash-beats-family")
    if class_of("gpt-5.6-terra") != "mid":
        raise ValueError("terra-beats-family")
    if class_of("deepseek-v4-flash") != "small":
        raise ValueError("deepseek-flash-small")
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
        "version": 2,
        "models": "stageScore+roleOf+normalizeOutboundScore+providerClassNeedles",
        "out": ["HMAC", "providerClass-price", "observe"],
        "slots": list(CANONICAL),
        "cases": cases,
        "scale": [dict(s) for s in SCALE],
        "titles": [{"title": t, "slot": sl} for t, sl in TITLES],
        "classes": [
            {
                "id": mid,
                "tier": tier,
                "source": "fallback" if tier == "unknown" else "needle",
            }
            for mid, tier in MODELS
        ],
        "filed": FILED,
    }
