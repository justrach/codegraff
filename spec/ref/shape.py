"""Executable port of lean-proofs/Graff/Shape.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from typing import Literal

Shape = Literal["review", "research", "design", "migration", "feature", "adhoc"]
Rung = Literal["R0", "R0d", "R1", "R2", "R3"]
TaskClass = Literal["bugfix", "feature", "refactor", "review", "research", "other"]
SHAPES: tuple[Shape, ...] = ("review", "research", "design", "migration", "feature", "adhoc")

# Representative strings for Zig classOf. Lean proves the reduced-cue order;
# these are the asks the comments name, plus one cell per remaining class.
CLASS_CASES: tuple[dict, ...] = (
    {"id": "audit_beats_bugfix", "raw": "thoroughly audit every file for bugs", "class": "review"},
    {"id": "repair_beats_review_word", "raw": "fix the bug the review found", "class": "bugfix"},
    {"id": "refactor", "raw": "refactor the module", "class": "refactor"},
    {"id": "review_word", "raw": "review this PR", "class": "review"},
    {"id": "research", "raw": "how does this work", "class": "research"},
    {"id": "feature", "raw": "add support for widgets", "class": "feature"},
    {"id": "other", "raw": "ponder the void", "class": "other"},
)


def parse_shape(s: str) -> Shape:
    return s if s in SHAPES else "adhoc"  # type: ignore[return-value]


@dataclass(frozen=True)
class Cues:
    audit: bool = False
    bugfix: bool = False
    refactor: bool = False
    review: bool = False
    research: bool = False
    feature: bool = False


def class_of(c: Cues) -> TaskClass:
    if c.audit:
        return "review"
    if c.bugfix:
        return "bugfix"
    if c.refactor:
        return "refactor"
    if c.review:
        return "review"
    if c.research:
        return "research"
    if c.feature:
        return "feature"
    return "other"


@dataclass(frozen=True)
class Observables:
    shape: Shape = "adhoc"
    files_lt3: bool = True
    widest_ge2: bool = False
    audit: bool = False
    prior_failure: bool = False
    prior_count: int = 0
    has_verifier: bool = False
    fleet_affordable: bool = True

    def case_id(self) -> str:
        return (
            f"{self.shape}.f{int(self.files_lt3)}.w{int(self.widest_ge2)}"
            f".a{int(self.audit)}.p{int(self.prior_failure)}c{self.prior_count}"
            f".v{int(self.has_verifier)}.aff{int(self.fleet_affordable)}"
        )


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
        Observables(shape, flt, wide, audit, prior, count, ver, aff)
        for shape, flt, wide, audit, prior, count, ver, aff in product(
            SHAPES,
            (False, True),
            (False, True),
            (False, True),
            (False, True),
            (0, 1, 2),
            (False, True),
            (False, True),
        )
    ]
