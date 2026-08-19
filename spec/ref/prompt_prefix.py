"""Executable port of lean-proofs/Graff/PromptPrefix.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Catalog = Literal["names_only", "with_bodies", "with_paths"]
Pin = Literal["once", "every_rebuild"]
# ("start", cat) | ("skill_load",) | ("skill_list",) | ("rescan",) | ("turn",)
# | ("rebuild_into_prefix", cat)
Event = tuple

CATALOGS: tuple[Catalog, ...] = ("names_only", "with_bodies", "with_paths")
PINS: tuple[Pin, ...] = ("once", "every_rebuild")
EVENTS: tuple[Event, ...] = (
    ("start", "names_only"),
    ("start", "with_bodies"),
    ("start", "with_paths"),
    ("skill_load",),
    ("skill_list",),
    ("rescan",),
    ("turn",),
    ("rebuild_into_prefix", "names_only"),
    ("rebuild_into_prefix", "with_bodies"),
    ("rebuild_into_prefix", "with_paths"),
)
KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "prompt_prefix.md"
CUBE = 6
HIT = 1


@dataclass(frozen=True)
class Cell:
    catalog: Catalog = "names_only"
    pin: Pin = "once"

    def case_id(self) -> str:
        return f"{self.catalog}.{self.pin}"


@dataclass(frozen=True)
class State:
    pinned: bool = False
    catalog: Catalog = "names_only"
    prefix_frozen: bool = False


def prefix_ok(catalog: Catalog) -> bool:
    return catalog == "names_only"


def pin_ok(pin: Pin) -> bool:
    return pin == "once"


def cacheable(c: Cell) -> bool:
    return prefix_ok(c.catalog) and pin_ok(c.pin)


def all_cells() -> list[Cell]:
    return [Cell(catalog, pin) for catalog, pin in product(CATALOGS, PINS)]


def step(s: State, e: Event) -> State:
    k = e[0]
    if k == "start":
        if s.pinned:
            return s
        return State(pinned=True, catalog=e[1], prefix_frozen=True)
    if k in ("skill_load", "skill_list", "rescan", "turn"):
        return s
    if k == "rebuild_into_prefix":
        cat = e[1]
        if not s.pinned:
            return State(pinned=True, catalog=cat, prefix_frozen=True)
        if cat == s.catalog:
            return s
        return State(pinned=s.pinned, catalog=cat, prefix_frozen=False)
    raise ValueError(f"unknown event {e!r}")


def run(s: State, es: list[Event]) -> State:
    for e in es:
        s = step(s, e)
    return s


def hit_ok(s: State) -> bool:
    return s.prefix_frozen and prefix_ok(s.catalog) and s.pinned


def project(s: State) -> str:
    if not s.pinned:
        return "Unpinned"
    if s.prefix_frozen and prefix_ok(s.catalog):
        return "Pinned"
    return "Busted"


def event_label(e: Event) -> str:
    k = e[0]
    if k == "start":
        return "start"
    if k == "rebuild_into_prefix":
        return "rebuild"
    return k


def walk(start: State | None = None) -> list[tuple[State, Event, State]]:
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


def diagram_edges() -> list[tuple[str, str, str]]:
    found: set[tuple[str, str, str]] = set()
    for s, e, t in walk():
        a, b = project(s), project(t)
        if a == b:
            continue
        found.add((a, event_label(e), b))
    return sorted(found)


def mermaid() -> str:
    lines = ["stateDiagram-v2", "  [*] --> Unpinned"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: prompt prefix (cache HIT)\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/PromptPrefix.lean`.\n"
        "\n"
        "Process kernel next to PromptCache. PromptCache is the key and the\n"
        "spawn gate. This kernel is the bytes under that key: names + triggers\n"
        "only, pinned once. Bodies and `file:` paths are illegal in the prefix.\n"
        "`skill` load / list / rescan / turn do not rewrite it. A mid-session\n"
        "rebuild that changes the catalog busts the prefix (Codex: the old\n"
        "prompt must be an exact prefix of the new one).\n"
        "\n"
        "Wording is out of Lean. The 6-cell cube is catalog kind × pin policy;\n"
        "exactly one cell is cacheable (`names_only` × `once`).\n"
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
                "cell": {"catalog": c.catalog, "pin": c.pin},
                "prefix_ok": prefix_ok(c.catalog),
                "pin_ok": pin_ok(c.pin),
                "cacheable": cacheable(c),
            }
        )
    return {"kernel": "prompt_prefix", "version": 1, "cases": cases}


def check_diagram() -> None:
    text = mermaid()
    if "Unpinned --> Pinned: start" not in text:
        raise ValueError("diagram: mermaid missing Unpinned start→Pinned")
    if "Pinned --> Busted: rebuild" not in text:
        raise ValueError("diagram: mermaid missing Pinned rebuild→Busted")
    if "Pinned --> Pinned: skill_load" in text:
        raise ValueError("diagram: skill_load should be id (no edge)")


def check_properties() -> int:
    n = 0
    hits = 0
    for c in all_cells():
        n += 1
        if c.catalog != "names_only" and prefix_ok(c.catalog):
            raise ValueError(f"bodies-or-paths-ok: {c.case_id()}")
        if c.pin == "every_rebuild" and pin_ok(c.pin):
            raise ValueError(f"rebuild-pin-ok: {c.case_id()}")
        if cacheable(c):
            hits += 1
            if c.catalog != "names_only" or c.pin != "once":
                raise ValueError(f"wrong-hit-cell: {c.case_id()}")
        elif c.catalog == "names_only" and c.pin == "once":
            raise ValueError(f"names-once-miss: {c.case_id()}")
    if n != CUBE:
        raise ValueError(f"prefix-cube: n={n} want={CUBE}")
    if hits != HIT:
        raise ValueError(f"hit-cells: n={hits} want={HIT}")
    idle = State()
    pinned = step(idle, ("start", "names_only"))
    if not hit_ok(pinned):
        raise ValueError("trace: names start should hit")
    if step(pinned, ("start", "with_paths")) != pinned:
        raise ValueError("trace: start is not once")
    for e in (("skill_load",), ("skill_list",), ("rescan",), ("turn",)):
        if step(pinned, e) != pinned:
            raise ValueError(f"trace: {e[0]} rewrote the prefix")
    if hit_ok(step(idle, ("start", "with_paths"))):
        raise ValueError("trace: paths start should miss")
    busted = run(idle, [("start", "names_only"), ("rebuild_into_prefix", "with_paths")])
    if hit_ok(busted) or busted.prefix_frozen:
        raise ValueError("trace: rebuild that changes catalog must bust")
    if not hit_ok(run(idle, [("start", "names_only"), ("rebuild_into_prefix", "names_only")])):
        raise ValueError("trace: same-catalog rebuild should stay")
    check_diagram()
    return n
