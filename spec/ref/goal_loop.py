"""Executable port of lean-proofs/Graff/GoalLoop.lean."""

from __future__ import annotations

from dataclasses import dataclass, replace
from itertools import product
from pathlib import Path
from typing import Literal

Seat = Literal["root", "sub", "review"]
Goal = Literal["none", "active", "paused", "blocked", "complete"]
Checklist = Literal["none", "open", "all_completed"]
Verdict = Literal["accept", "refuse_open", "refuse_no_plan"]
# ("setGoal", standing) | ("pause",) | ("resume",) | ("clear",)
# | ("write", checklist) | ("attempt",)
Event = tuple

SEATS: tuple[Seat, ...] = ("root", "sub", "review")
GOALS: tuple[Goal, ...] = ("none", "active", "paused", "blocked", "complete")
LISTS: tuple[Checklist, ...] = ("none", "open", "all_completed")
LIVE_GOALS = frozenset({"active", "paused", "blocked"})
EVENTS: tuple[Event, ...] = (
    ("setGoal", False),
    ("setGoal", True),
    ("pause",),
    ("resume",),
    ("clear",),
    ("write", "open"),
    ("write", "all_completed"),
    ("attempt",),
)
KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "goal_loop.md"


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


def live_goal(g: Goal) -> bool:
    return g in LIVE_GOALS


def step(s: State, e: Event) -> State:
    k = e[0]
    if k == "setGoal":
        standing = e[1]
        if live_goal(s.goal):
            return State(seat=s.seat, goal="active", standing=standing)
        return replace(s, goal="active", standing=standing, armed=False)
    if k == "pause":
        return replace(s, goal="paused") if s.goal == "active" else s
    if k == "resume":
        return replace(s, goal="active") if s.goal == "paused" else s
    if k == "clear":
        return replace(s, goal="none", standing=False, checklist="none", dirty=False, armed=False)
    if k == "write":
        c = e[1]
        if c == "none":
            return s
        return replace(s, checklist=c, dirty=True, armed=False)
    if k == "attempt":
        v = completion_gate(s)
        if v in ("refuse_open", "refuse_no_plan"):
            return replace(s, armed=True)
        s2 = replace(s, armed=False)
        return replace(s2, goal="complete") if retires_on_accept(s) else s2
    raise ValueError(f"unknown event {e!r}")


def run(s: State, es: list[Event]) -> State:
    for e in es:
        s = step(s, e)
    return s


def writes_done(e: Event) -> bool:
    return e[0] == "write" and e[1] == "all_completed"


def project(s: State) -> str:
    """Root-seat labels for the diagram. Seat is configuration, not an event."""
    if s.goal == "none":
        return "Idle"
    if s.goal == "complete":
        return "Complete"
    if s.goal == "blocked":
        return "StandBlocked" if s.standing else "TaskBlocked"
    if s.goal == "paused":
        return "StandPaused" if s.standing else "Paused"
    if s.armed:
        return "StandArmed" if s.standing else "TaskArmed"
    if s.checklist == "open":
        return "StandOpen" if s.standing else "TaskOpen"
    if s.checklist == "all_completed":
        return "StandDone" if s.standing else "TaskDone"
    return "Standing" if s.standing else "Task"


def event_label(s: State, e: Event) -> str:
    k = e[0]
    if k == "setGoal":
        return "setGoal standing" if e[1] else "setGoal"
    if k == "write":
        return "write done" if e[1] == "all_completed" else "write open"
    if k == "attempt":
        v = completion_gate(s)
        return f"attempt / {v}" if v.startswith("refuse") else "attempt"
    return k


def walk(start: State | None = None) -> list[tuple[State, Event, State]]:
    """Every non-identity `step` reachable from idle under EVENTS."""
    src = start or State()
    seen = {src}
    q = [src]
    out: list[tuple[State, Event, State]] = []
    while q:
        s = q.pop()
        for e in EVENTS:
            t = step(s, e)
            if t == s:
                continue
            out.append((s, e, t))
            if t not in seen:
                seen.add(t)
                q.append(t)
    return out


def _display(s: State, e: Event, t: State) -> bool:
    """Small projection: lifecycle events, plus setGoal entry and clear exit."""
    a, b = project(s), project(t)
    if a == b:
        return False
    k = e[0]
    if k in ("attempt", "pause", "resume", "write"):
        return True
    if k == "setGoal" and a in ("Idle", "Complete"):
        return True
    if k == "clear" and b == "Idle":
        return True
    return False


def diagram_edges() -> list[tuple[str, str, str]]:
    found: set[tuple[str, str, str]] = set()
    for s, e, t in walk():
        if _display(s, e, t):
            found.add((project(s), event_label(s, e), project(t)))
    return sorted(found)



def payload() -> dict:
    cases = []
    for s in all_states():
        cases.append(
            {
                "id": s.case_id(),
                "state": {
                    "seat": s.seat,
                    "goal": s.goal,
                    "standing": s.standing,
                    "checklist": s.checklist,
                    "dirty": s.dirty,
                    "armed": s.armed,
                },
                "completion_gate": completion_gate(s),
                "checklist_finished": checklist_finished(s),
                "retires_on_accept": retires_on_accept(s),
            }
        )
    return {"kernel": "goal_loop", "version": 1, "cases": cases}


def mermaid() -> str:
    lines = ["stateDiagram-v2", "  [*] --> Idle"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: goal / completion\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/GoalLoop.lean`.\n"
        "\n"
        "Process kernel, not a cube and not a Turing machine: finite `Event` / `step`,\n"
        "no tape, no halt state. The 360-cell cube is the snapshot of that machine.\n"
        "GoalLoop is the worked example. Standing has no retire edge. Harness-done\n"
        "is unreachable without a `write allCompleted`. World-done is not an event.\n"
        "\n"
        "The diagram is the root-seat projection of the live Python `step`\n"
        "(same function `check_properties` walks). Emit it with\n"
        "`python3 spec/conformance.py --diagram goal_loop`. `--export` rewrites\n"
        "the fence below from that function; do not hand-edit the arrows.\n"
        "\n"
        "```mermaid\n"
        f"{body}\n"
        "```\n"
    )


def write_kernel_md(path: Path = KERNEL_MD) -> Path:
    path.write_text(kernel_md())
    return path


def check_diagram() -> None:
    raw = walk()
    saw_arm = False
    for s, e, t in raw:
        if e[0] != "attempt":
            continue
        if completion_gate(s) in ("refuse_open", "refuse_no_plan"):
            if t.armed and t.goal == s.goal:
                saw_arm = True
            else:
                raise ValueError(f"diagram: refuse did not arm {s.case_id()}")
        if s.standing and t.goal == "complete":
            raise ValueError(f"diagram: standing attempt retired {s.case_id()}")
    if not saw_arm:
        raise ValueError("diagram: missing refuse→arm on live step")
    text = mermaid()
    if "attempt / refuse_no_plan" not in text and "attempt / refuse_open" not in text:
        raise ValueError("diagram: mermaid missing refuse→arm label")
    if "Task --> TaskArmed: attempt / refuse_no_plan" not in text:
        raise ValueError("diagram: mermaid missing Task refuse-no-plan arm")
    for banned in (
        "StandArmed --> Complete",
        "StandDone --> Complete",
        "Standing --> Complete",
        "StandOpen --> Complete",
        "StandPaused --> Complete",
    ):
        if banned in text:
            raise ValueError(f"diagram: standing attempt→complete in mermaid ({banned})")


def check_properties() -> int:
    n = 0
    for s in all_states():
        n += 1
        v = completion_gate(s)
        if s.seat != "root" and v != "accept":
            raise ValueError(f"non-root-never-refuses: {s.case_id()} gate={v}")
        if s.goal != "active" and v != "accept":
            raise ValueError(f"inactive-never-refuses: {s.case_id()} gate={v}")
        if s.checklist == "none" and checklist_finished(s):
            raise ValueError(f"empty-never-done: {s.case_id()}")
        if goal_active(s) and not s.armed and s.checklist == "open" and v != "refuse_open":
            raise ValueError(f"open-refused: {s.case_id()} gate={v}")
        if goal_active(s) and not s.armed and s.checklist == "none" and v != "refuse_no_plan":
            raise ValueError(f"empty-refused: {s.case_id()} gate={v}")
        if goal_active(s) and not s.armed and s.checklist == "all_completed" and v != "accept":
            raise ValueError(f"done-accepted: {s.case_id()} gate={v}")
        if s.armed and goal_active(s) and v != "accept":
            raise ValueError(f"armed-accepts: {s.case_id()} gate={v}")
        if s.dirty is False and checklist_finished(s):
            raise ValueError(f"finished-needs-dirty: {s.case_id()}")
        if s.standing and retires_on_accept(s):
            raise ValueError(f"standing-does-not-retire: {s.case_id()}")
        if goal_active(s) and not s.standing and not retires_on_accept(s):
            raise ValueError(f"active-retires: {s.case_id()}")
        if step(s, ("write", "none")) != s:
            raise ValueError(f"write-none-id: {s.case_id()}")
        if checklist_finished(step(s, ("write", "open"))):
            raise ValueError(f"write-open-never-finished: {s.case_id()}")
        if s.standing and step(s, ("attempt",)).goal != s.goal:
            raise ValueError(f"standing-attempt-preserves-goal: {s.case_id()}")
        if s.seat != "root" and step(s, ("attempt",)).goal != s.goal:
            raise ValueError(f"non-root-attempt-preserves-goal: {s.case_id()}")
        if s.goal == "paused" and step(s, ("attempt",)).goal != s.goal:
            raise ValueError(f"paused-attempt-preserves-goal: {s.case_id()}")
        if v in ("refuse_open", "refuse_no_plan"):
            a = step(s, ("attempt",))
            if not a.armed or a.goal != s.goal:
                raise ValueError(f"refuse-arms: {s.case_id()}")
        a = step(s, ("attempt",))
        if a.checklist != s.checklist or a.dirty != s.dirty:
            raise ValueError(f"attempt-keeps-list: {s.case_id()}")
    if n != 360:
        raise ValueError(f"goal-cube: n={n} want=360")
    idle = State()
    if run(idle, [("setGoal", False), ("attempt",)]).armed is not True:
        raise ValueError("trace: first attempt on empty must arm")
    if run(idle, [("setGoal", False), ("attempt",), ("attempt",)]).goal != "complete":
        raise ValueError("trace: double-check retires a task goal")
    if run(idle, [("setGoal", True), ("attempt",), ("attempt",)]).goal != "active":
        raise ValueError("trace: standing has no retire edge")
    if run(idle, [("setGoal", False), ("write", "all_completed"), ("attempt",)]).goal != "complete":
        raise ValueError("trace: done write then attempt retires")
    if checklist_finished(run(idle, [("setGoal", False), ("write", "open"), ("attempt",)])):
        raise ValueError("trace: open write never finishes")
    check_diagram()
    return n
