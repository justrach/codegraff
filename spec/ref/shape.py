"""Executable port of lean-proofs/Graff/Shape.lean.

Affordability is Ledger.fits(remaining, fleetFloor(shape)), not a free bool.
Classifier cases are built from src/shape_needles.zig (the live scan's table).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Shape = Literal["review", "research", "design", "migration", "feature", "adhoc"]
Rung = Literal["R0", "R0d", "R1", "R2", "R3"]
TaskClass = Literal["bugfix", "feature", "refactor", "review", "research", "other"]
SHAPES: tuple[Shape, ...] = ("review", "research", "design", "migration", "feature", "adhoc")
NEEDLE_KEYS = ("audit", "bugfix", "refactor", "review", "research", "feature")
NEEDLES_ZIG = Path(__file__).resolve().parents[2] / "src" / "shape_needles.zig"

# phase_budget.zig
COST_FIND = 4
COST_VERIFY = 3
COST_SYNTHESIZE = 2
COST_IMPLEMENT = 6
COST_DEFAULT = 3
MIN_LANDING_RESERVE = 6
COST_NARRATION = 1  # #390: one call reserved to narrate the run's outcome

# dry / split (spendable 9: adhoc fits, design does not) / wet
BUDGETS: tuple[tuple[int, int], ...] = ((0, 100), (30, 100), (1_000_000, 1_000_000))
CUBE = 1728  # 6 shapes × 2⁵ bools × 3 prior-counts × 3 budgets


def parse_shape(s: str) -> Shape:
    return s if s in SHAPES else "adhoc"  # type: ignore[return-value]


def fleet_floor(shape: Shape) -> int:
    return {
        "review": 3 * COST_FIND + COST_VERIFY + COST_SYNTHESIZE,
        "research": 3 * COST_FIND + COST_SYNTHESIZE,
        "design": 3 * COST_IMPLEMENT,
        "feature": COST_VERIFY + COST_IMPLEMENT + COST_VERIFY,
        "migration": 4 * COST_DEFAULT,
        "adhoc": 3 * COST_DEFAULT,
    }[shape]


def landing_reserve(cap: int) -> int:
    return max(MIN_LANDING_RESERVE, cap // 5)


def total_reserve(cap: int) -> int:
    return landing_reserve(cap) + COST_NARRATION


def fleet_fits(shape: Shape, remaining: int, cap: int) -> bool:
    if cap == 0:
        return True
    return remaining - total_reserve(cap) >= fleet_floor(shape)


def load_needles(path: Path = NEEDLES_ZIG) -> dict[str, list[str]]:
    text = path.read_text()
    out: dict[str, list[str]] = {}
    for m in re.finditer(r"pub const (\w+) = \[_\]\[\]const u8\{([^}]*)\}", text, re.S):
        body = m.group(2)
        out[m.group(1)] = re.findall(r'"((?:\\.|[^"\\])*)"', body)
    missing = [k for k in NEEDLE_KEYS if k not in out]
    if missing:
        raise RuntimeError(f"shape_needles.zig missing {missing}")
    return out


def any_of_ci(hay: str, needles: list[str]) -> bool:
    low = hay.lower()
    return any(n.lower() in low for n in needles)


def class_of_raw(raw: str, needles: dict[str, list[str]] | None = None) -> TaskClass:
    n = needles or load_needles()
    if any_of_ci(raw, n["audit"]):
        return "review"
    if any_of_ci(raw, n["bugfix"]):
        return "bugfix"
    if any_of_ci(raw, n["refactor"]):
        return "refactor"
    if any_of_ci(raw, n["review"]):
        return "review"
    if any_of_ci(raw, n["research"]):
        return "research"
    if any_of_ci(raw, n["feature"]):
        return "feature"
    return "other"


def class_cases(needles: dict[str, list[str]] | None = None) -> list[dict]:
    n = needles or load_needles()
    return [
        {
            "id": "audit_beats_bugfix",
            "raw": f"{n['audit'][0]} {n['bugfix'][0]}extra",
            "class": "review",
        },
        {
            "id": "repair_beats_review_word",
            "raw": f"{n['bugfix'][0]}the {n['review'][0]} found",
            "class": "bugfix",
        },
        {"id": "refactor", "raw": n["refactor"][0], "class": "refactor"},
        {"id": "review_word", "raw": n["review"][0], "class": "review"},
        {"id": "research", "raw": n["research"][0], "class": "research"},
        {"id": "feature", "raw": n["feature"][0], "class": "feature"},
        {"id": "other", "raw": "ponder the void", "class": "other"},
    ]


@dataclass(frozen=True)
class Observables:
    shape: Shape = "adhoc"
    files_lt3: bool = True
    widest_ge2: bool = False
    audit: bool = False
    prior_failure: bool = False
    prior_count: int = 0
    has_verifier: bool = False
    remaining: int = 1_000_000
    cap: int = 1_000_000

    def case_id(self) -> str:
        return (
            f"{self.shape}.f{int(self.files_lt3)}.w{int(self.widest_ge2)}"
            f".a{int(self.audit)}.p{int(self.prior_failure)}c{self.prior_count}"
            f".v{int(self.has_verifier)}.r{self.remaining}.c{self.cap}"
        )

    @property
    def fleet_affordable(self) -> bool:
        return fleet_fits(self.shape, self.remaining, self.cap)


def ladder_rung(o: Observables) -> Rung:
    if (
        o.prior_failure
        and not o.audit
        and o.prior_count == 1
        and o.files_lt3
        and o.has_verifier
    ):
        return "R0d"
    if (o.audit or o.prior_failure) and o.fleet_affordable:
        return "R3"
    if o.shape == "research" and not o.audit:
        return "R1"
    if (not o.files_lt3) and o.widest_ge2 and o.fleet_affordable:
        return "R2"
    return "R0"


def level(r: Rung) -> int:
    return {"R0": 0, "R0d": 1, "R1": 2, "R2": 3, "R3": 4}[r]


def honour_explicit(ladder: Rung) -> Rung:
    return ladder if level(ladder) >= 3 else "R2"


def all_observables() -> list[Observables]:
    return [
        Observables(shape, flt, wide, audit, prior, count, ver, rem, cap)
        for shape, flt, wide, audit, prior, count, ver, (rem, cap) in product(
            SHAPES,
            (False, True),
            (False, True),
            (False, True),
            (False, True),
            (0, 1, 2),
            (False, True),
            BUDGETS,
        )
    ]


def payload() -> dict:
    needles = load_needles()
    cases = []
    for o in all_observables():
        r = ladder_rung(o)
        cases.append(
            {
                "id": o.case_id(),
                "obs": {
                    "shape": o.shape,
                    "files_lt3": o.files_lt3,
                    "widest_ge2": o.widest_ge2,
                    "audit": o.audit,
                    "prior_failure": o.prior_failure,
                    "prior_count": o.prior_count,
                    "has_verifier": o.has_verifier,
                    "remaining": o.remaining,
                    "cap": o.cap,
                },
                "ladder": r,
                "explicit": honour_explicit(r),
            }
        )
    split_adhoc = Observables(
        shape="adhoc", files_lt3=False, widest_ge2=True, remaining=30, cap=100
    )
    split_design = Observables(
        shape="design", files_lt3=False, widest_ge2=True, remaining=30, cap=100
    )
    return {
        "kernel": "shape",
        "version": 2,
        "models": "ladderRung+explicit",
        "out": ["observe", "override", "explore"],
        "cases": cases,
        "needles": {k: needles[k] for k in NEEDLE_KEYS},
        "class_cases": class_cases(needles),
        "split": {
            "remaining": 30,
            "cap": 100,
            "adhoc_ladder": ladder_rung(split_adhoc),
            "design_ladder": ladder_rung(split_design),
        },
    }


def check_properties() -> int:
    n = 0
    for o in all_observables():
        n += 1
        r = ladder_rung(o)
        if o.prior_failure and not o.audit and o.prior_count == 1 and o.files_lt3 and o.has_verifier:
            if r != "R0d":
                raise ValueError(f"first-fail-small-verified-is-R0d: {o} {r}")
        elif (o.audit or o.prior_failure) and o.fleet_affordable:
            if r != "R3":
                raise ValueError(f"audit-or-fail-affordable-is-R3: {o} {r}")
        elif o.shape == "research" and not o.audit:
            if r != "R1":
                raise ValueError(f"research-is-R1: {o} {r}")
        elif (not o.files_lt3) and o.widest_ge2 and o.fleet_affordable:
            if r != "R2":
                raise ValueError(f"three-files-is-R2: {o} {r}")
        elif r != "R0":
            raise ValueError(f"floor-is-R0: {o} {r}")
        hon = honour_explicit(r)
        if level(hon) < 3:
            raise ValueError(f"explicit-at-least-R2: {hon}")
        if r == "R3" and hon != "R3":
            raise ValueError(f"explicit-keeps-R3: {hon}")
        if level(r) < 3 and hon != "R2":
            raise ValueError(f"explicit-lifts-below-R2: {hon}")
    if n != CUBE:
        raise ValueError(f"shape-cube: n={n} want={CUBE}")
    if not fleet_fits("adhoc", 30, 100) or fleet_fits("design", 30, 100):
        raise ValueError("split-budget: remaining=30 cap=100 must admit adhoc and refuse design")
    split_a = Observables(shape="adhoc", files_lt3=False, widest_ge2=True, remaining=30, cap=100)
    split_d = Observables(shape="design", files_lt3=False, widest_ge2=True, remaining=30, cap=100)
    if ladder_rung(split_a) != "R2" or ladder_rung(split_d) != "R0":
        raise ValueError(
            f"split-ladder: adhoc={ladder_rung(split_a)} design={ladder_rung(split_d)}"
        )
    if parse_shape("ponder") != "adhoc" or parse_shape("review") != "review":
        raise ValueError("parse-shape: unknown must be adhoc")
    needles = load_needles()
    for case in class_cases(needles):
        got = class_of_raw(case["raw"], needles)
        if got != case["class"]:
            raise ValueError(f"{case['id']}: class want={case['class']} got={got}")
    return n
