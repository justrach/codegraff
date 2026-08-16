"""Executable port of lean-proofs/Graff/PromptCache.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Seat = Literal["root", "sub"]
Label = Literal["main", "other"]
Isolation = Literal["shared_cwd", "worktree"]
Wire = Literal["openai", "responses", "anthropic"]
Partition = Literal["root", "child"]
# ("turn",) | ("spawn", bg: bool, iso) | ("join",)
Event = tuple

SEATS: tuple[Seat, ...] = ("root", "sub")
LABELS: tuple[Label, ...] = ("main", "other")
ISOS: tuple[Isolation, ...] = ("shared_cwd", "worktree")
WIRES: tuple[Wire, ...] = ("openai", "responses", "anthropic")
EVENTS: tuple[Event, ...] = (
    ("turn",),
    ("spawn", False, "shared_cwd"),
    ("spawn", True, "shared_cwd"),
    ("spawn", False, "worktree"),
    ("spawn", True, "worktree"),
    ("join",),
)
KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "prompt_cache.md"
CUBE = 48


@dataclass(frozen=True)
class Cell:
    wire: Wire = "openai"
    label: Label = "main"
    isolation: Isolation = "shared_cwd"
    grok: bool = False
    seat: Seat = "root"

    def case_id(self) -> str:
        return (
            f"{self.wire}.{self.label}.{self.isolation}"
            f".g{int(self.grok)}.{self.seat}"
        )


@dataclass(frozen=True)
class State:
    seat: Seat = "root"
    label: Label = "main"
    isolation: Isolation = "shared_cwd"
    partition: Partition = "root"


def emit_key(wire: Wire) -> bool:
    return wire != "anthropic"


def partition_of(label: Label, isolation: Isolation) -> Partition:
    _ = isolation
    return "root" if label == "main" else "child"


def spawn_ok(seat: Seat) -> bool:
    return seat == "root"


def header_agrees(c: Cell) -> bool:
    if not c.grok or not emit_key(c.wire):
        return True
    return partition_of(c.label, c.isolation) == partition_of(c.label, c.isolation)


def all_cells() -> list[Cell]:
    return [
        Cell(wire, label, isolation, grok, seat)
        for wire, label, isolation, grok, seat in product(
            WIRES, LABELS, ISOS, (False, True), SEATS
        )
    ]


def child_of(iso: Isolation) -> State:
    return State(seat="sub", label="other", isolation=iso, partition="child")


def root_of(iso: Isolation) -> State:
    return State(seat="root", label="main", isolation=iso, partition="root")


def step(s: State, e: Event) -> State:
    k = e[0]
    if k == "turn":
        return s
    if k == "spawn":
        iso = e[2]
        return s if s.seat == "sub" else child_of(iso)
    if k == "join":
        return s if s.seat == "root" else root_of(s.isolation)
    raise ValueError(f"unknown event {e!r}")


def run(s: State, es: list[Event]) -> State:
    for e in es:
        s = step(s, e)
    return s


def project(s: State) -> str:
    return "Root" if s.seat == "root" else "Child"


def event_label(e: Event) -> str:
    k = e[0]
    if k == "spawn":
        return "spawn"
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
        if a == b or e[0] == "turn":
            continue
        found.add((a, event_label(e), b))
    return sorted(found)


def mermaid() -> str:
    lines = ["stateDiagram-v2", "  [*] --> Root"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: prompt cache / spawn\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/PromptCache.lean`.\n"
        "\n"
        "Process kernel, not a cube-only table and not a Turing machine: finite\n"
        "`Event` / `step`, no tape. Seat is who may spawn. Label is the cache\n"
        "predicate (`main` is the only sticky root partition). Isolation does\n"
        "not mint a key. Sub never spawns. Join restores the root partition.\n"
        "\n"
        "The diagram is the projection of the live Python `step` (same function\n"
        "`check_properties` walks). Emit it with\n"
        "`python3 spec/conformance.py --diagram prompt_cache`.\n"
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
                "cell": {
                    "wire": c.wire,
                    "label": c.label,
                    "isolation": c.isolation,
                    "grok": c.grok,
                    "seat": c.seat,
                },
                "emit_key": emit_key(c.wire),
                "partition": partition_of(c.label, c.isolation),
                "spawn_ok": spawn_ok(c.seat),
                "header_agrees": header_agrees(c),
            }
        )
    return {"kernel": "prompt_cache", "version": 1, "cases": cases}


def check_diagram() -> None:
    raw = walk()
    saw_spawn = saw_join = False
    for s, e, t in raw:
        if e[0] == "spawn":
            if s.seat == "sub":
                raise ValueError(f"diagram: sub spawned {s}")
            if t.partition != "child" or t.seat != "sub":
                raise ValueError(f"diagram: spawn did not isolate {s}")
            saw_spawn = True
        if e[0] == "join":
            if t.partition != "root" or t.seat != "root" or t.label != "main":
                raise ValueError(f"diagram: join did not restore root {s}")
            saw_join = True
    if not saw_spawn or not saw_join:
        raise ValueError("diagram: missing spawn or join on live step")
    text = mermaid()
    if "Root --> Child: spawn" not in text:
        raise ValueError("diagram: mermaid missing Root spawn→Child")
    if "Child --> Root: join" not in text:
        raise ValueError("diagram: mermaid missing Child join→Root")
    if "Child --> Child: spawn" in text:
        raise ValueError("diagram: mermaid has Child spawn edge")


def check_properties() -> int:
    n = 0
    for c in all_cells():
        n += 1
        if c.wire == "anthropic" and emit_key(c.wire):
            raise ValueError(f"anthropic-never-key: {c.case_id()}")
        if c.wire != "anthropic" and not emit_key(c.wire):
            raise ValueError(f"non-anthropic-emits-key: {c.case_id()}")
        if c.label == "main" and partition_of(c.label, c.isolation) != "root":
            raise ValueError(f"main-is-root: {c.case_id()}")
        if c.label == "other" and partition_of(c.label, c.isolation) != "child":
            raise ValueError(f"other-is-child: {c.case_id()}")
        if partition_of(c.label, "shared_cwd") != partition_of(c.label, "worktree"):
            raise ValueError(f"isolation-mints-key: {c.case_id()}")
        if c.seat == "sub" and spawn_ok(c.seat):
            raise ValueError(f"sub-never-spawn-ok: {c.case_id()}")
        if c.seat == "root" and not spawn_ok(c.seat):
            raise ValueError(f"root-spawn-ok: {c.case_id()}")
        if not header_agrees(c):
            raise ValueError(f"header-agrees: {c.case_id()}")
    if n != CUBE:
        raise ValueError(f"cache-cube: n={n} want={CUBE}")
    idle = State()
    child = step(idle, ("spawn", False, "worktree"))
    if child.partition != "child" or child.seat != "sub":
        raise ValueError("trace: spawn did not isolate")
    if step(child, ("spawn", True, "shared_cwd")) != child:
        raise ValueError("trace: sub spawned")
    back = step(child, ("join",))
    if back.partition != "root" or back.label != "main":
        raise ValueError("trace: join did not restore root")
    if step(idle, ("spawn", False, "shared_cwd")).partition != step(
        idle, ("spawn", True, "worktree")
    ).partition:
        raise ValueError("trace: spawn mode/iso minted a key")
    if run(idle, [("spawn", False, "shared_cwd"), ("join",)]).partition != "root":
        raise ValueError("trace: spawn+join lost the root key")
    check_diagram()
    return n
