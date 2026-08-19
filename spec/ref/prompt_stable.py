"""Executable port of lean-proofs/Graff/PromptStable.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Event = Literal[
    "turn",
    "skill_inject",
    "schema_load",
    "toolset_append",
    "toolset_rewrite",
    "clock_tick",
    "memory_reload",
    "set_system_prompt",
    "standing_change",
    "compact",
]
Land = Literal["history", "prefix"]
Verdict = Literal["keep", "bust", "illegal"]
# ("start",) | ("ev", Event)
StepEvent = tuple

EVENTS: tuple[Event, ...] = (
    "turn",
    "skill_inject",
    "schema_load",
    "toolset_append",
    "toolset_rewrite",
    "clock_tick",
    "memory_reload",
    "set_system_prompt",
    "standing_change",
    "compact",
)
LANDS: tuple[Land, ...] = ("history", "prefix")
KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "prompt_stable.md"
CUBE = 20
KEEP = 5
HISTORY = frozenset({"turn", "skill_inject", "schema_load"})
KEEP_EVENTS = frozenset({"turn", "skill_inject", "schema_load", "toolset_append", "compact"})
BUST_EVENTS = frozenset({"set_system_prompt", "standing_change"})
ILLEGAL_EVENTS = frozenset({"clock_tick", "toolset_rewrite", "memory_reload"})


@dataclass(frozen=True)
class Cell:
    event: Event
    land: Land

    def case_id(self) -> str:
        return f"{self.event}.{self.land}"


@dataclass(frozen=True)
class State:
    pinned: bool = False
    frozen: bool = False


def land(e: Event) -> Land:
    return "history" if e in HISTORY else "prefix"


def verdict(e: Event) -> Verdict:
    if e in KEEP_EVENTS:
        return "keep"
    if e in BUST_EVENTS:
        return "bust"
    return "illegal"


def keep(c: Cell) -> bool:
    return land(c.event) == c.land and verdict(c.event) == "keep"


def all_cells() -> list[Cell]:
    return [Cell(e, l) for e, l in product(EVENTS, LANDS)]


def step(s: State, e: StepEvent) -> State:
    if e[0] == "start":
        return s if s.pinned else State(pinned=True, frozen=True)
    ev = e[1]
    if not s.pinned:
        return s
    if verdict(ev) == "keep":
        return State(pinned=True, frozen=True) if ev == "compact" else s
    return State(pinned=s.pinned, frozen=False)


def run(s: State, es: list[StepEvent]) -> State:
    for e in es:
        s = step(s, e)
    return s


def hit_ok(s: State) -> bool:
    return s.pinned and s.frozen


def project(s: State) -> str:
    if not s.pinned:
        return "Unpinned"
    return "Frozen" if s.frozen else "Busted"


def event_label(e: StepEvent) -> str:
    return "start" if e[0] == "start" else e[1]


def walk(start: State | None = None) -> list[tuple[State, StepEvent, State]]:
    src = start or State()
    events: list[StepEvent] = [("start",)] + [("ev", ev) for ev in EVENTS]
    seen = {src}
    q = [src]
    out: list[tuple[State, StepEvent, State]] = []
    while q:
        s = q.pop()
        for e in events:
            t = step(s, e)
            if t == s:
                continue
            out.append((s, e, t))
            if t not in seen:
                seen.add(t)
                q.append(t)
    return out


def mermaid() -> str:
    found: set[tuple[str, str, str]] = set()
    for s, e, t in walk():
        a, b = project(s), project(t)
        if a == b:
            continue
        found.add((a, event_label(e), b))
    lines = ["stateDiagram-v2", "  [*] --> Unpinned"]
    for a, lab, b in sorted(found):
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: prompt stable (OpenGauss must-nots)\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/PromptStable.lean`.\n"
        "\n"
        "Process kernel next to PromptCache / PromptPrefix. PromptCache is\n"
        "the key. PromptPrefix is the catalog bytes. This kernel is what\n"
        "may touch the prefix after pin — OpenGauss's \"Prompt Caching Must\n"
        "Not Break\": no past-context rewrite, no toolset rewrite, no memory\n"
        "reload or system-prompt rebuild mid-session. Compression is the\n"
        "allowed rewrite. Skills and folded schemas land in history.\n"
        "\n"
        "graff keeps two explicit busts (`set_system_prompt`, `/goal` line)\n"
        "and one append-only tools tail (#476). Mid-array rewrite is still\n"
        "illegal. Anthropic `cache_control` placement is out of Lean.\n"
        "\n"
        "20 cells (event × land). Exactly 5 keep. Showcase with\n"
        "`python3 spec/conformance.py --showcase`.\n"
        "\n"
        "```mermaid\n"
        f"{body}\n"
        "```\n"
    )


def write_kernel_md(path: Path = KERNEL_MD) -> Path:
    path.write_text(kernel_md())
    return path


def payload() -> dict:
    cases = []
    for c in all_cells():
        cases.append(
            {
                "id": c.case_id(),
                "cell": {"event": c.event, "land": c.land},
                "land": land(c.event),
                "verdict": verdict(c.event),
                "keep": keep(c),
            }
        )
    return {"kernel": "prompt_stable", "version": 1, "cases": cases}


def check_properties() -> int:
    n = 0
    keeps = 0
    for c in all_cells():
        n += 1
        if c.event in HISTORY and land(c.event) != "history":
            raise ValueError(f"history-land: {c.case_id()}")
        if c.event not in HISTORY and land(c.event) != "prefix":
            raise ValueError(f"prefix-land: {c.case_id()}")
        if keep(c):
            keeps += 1
            if land(c.event) != c.land or verdict(c.event) != "keep":
                raise ValueError(f"wrong-keep: {c.case_id()}")
        elif land(c.event) == c.land and verdict(c.event) == "keep":
            raise ValueError(f"missed-keep: {c.case_id()}")
    if n != CUBE:
        raise ValueError(f"stable-cube: n={n} want={CUBE}")
    if keeps != KEEP:
        raise ValueError(f"keep-cells: n={keeps} want={KEEP}")
    idle = State()
    pinned = step(idle, ("start",))
    if not hit_ok(pinned):
        raise ValueError("trace: start should hit")
    for ev in ("turn", "skill_inject", "schema_load", "toolset_append"):
        if step(pinned, ("ev", ev)) != pinned:
            raise ValueError(f"trace: {ev} rewrote the prefix")
    if not hit_ok(run(idle, [("start",), ("ev", "compact")])):
        raise ValueError("trace: compact should re-pin")
    if hit_ok(run(idle, [("start",), ("ev", "set_system_prompt")])):
        raise ValueError("trace: set_system_prompt should bust")
    if hit_ok(run(idle, [("start",), ("ev", "clock_tick")])):
        raise ValueError("trace: clock_tick should bust")
    if hit_ok(run(idle, [("start",), ("ev", "toolset_rewrite")])):
        raise ValueError("trace: toolset_rewrite should bust")
    if hit_ok(run(idle, [("start",), ("ev", "memory_reload")])):
        raise ValueError("trace: memory_reload should bust")
    walk_ok = run(
        idle,
        [
            ("start",),
            ("ev", "turn"),
            ("ev", "skill_inject"),
            ("ev", "schema_load"),
            ("ev", "toolset_append"),
            ("ev", "compact"),
        ],
    )
    if not hit_ok(walk_ok):
        raise ValueError("trace: maximizing walk left the HIT cell")
    if keep(Cell("skill_inject", "prefix")):
        raise ValueError("trace: skill in prefix must miss")
    return n
