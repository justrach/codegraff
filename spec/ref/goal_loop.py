"""Executable port of lean-proofs/Graff/GoalLoop.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from typing import Literal

Seat = Literal["root", "sub", "review"]
Goal = Literal["none", "active", "paused", "blocked", "complete"]
Checklist = Literal["none", "open", "all_completed"]
Verdict = Literal["accept", "refuse_open", "refuse_no_plan"]

SEATS: tuple[Seat, ...] = ("root", "sub", "review")
GOALS: tuple[Goal, ...] = ("none", "active", "paused", "blocked", "complete")
LISTS: tuple[Checklist, ...] = ("none", "open", "all_completed")


@dataclass(frozen=True)
class State:
    seat: Seat = "root"
    goal: Goal = "none"
    standing: bool = False
    checklist: Checklist = "none"
    dirty: bool = False
    armed: bool = False

    def case_id(self) -> str:
        return (
            f"{self.seat}.{self.goal}.st{int(self.standing)}"
            f".{self.checklist}.d{int(self.dirty)}.a{int(self.armed)}"
        )


def goal_active(s: State) -> bool:
    return s.seat == "root" and s.goal == "active"


def all_done(c: Checklist) -> bool:
    return c == "all_completed"


def completion_gate(s: State) -> Verdict:
    if not goal_active(s):
        return "accept"
    if s.armed:
        return "accept"
    if s.checklist == "open":
        return "refuse_open"
    if s.checklist == "none":
        return "refuse_no_plan"
    return "accept"


def checklist_finished(s: State) -> bool:
    return s.dirty and all_done(s.checklist)


def retires_on_accept(s: State) -> bool:
    return goal_active(s) and not s.standing


def all_states() -> list[State]:
    bits = (False, True)
    return [
        State(seat, goal, standing, checklist, dirty, armed)
        for seat, goal, standing, checklist, dirty, armed in product(
            SEATS, GOALS, bits, LISTS, bits, bits
        )
    ]
