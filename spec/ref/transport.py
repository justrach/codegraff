"""Executable port of lean-proofs/Graff/Transport.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Kind = Literal["anthropic", "openai", "responses", "interactions"]
Pipe = Literal["ws", "sse"]
KINDS: tuple[Kind, ...] = ("anthropic", "openai", "responses")
Event = tuple  # ("setKind", kind) | ("markSub",) | ("joinRoot",) | ("setCodexWs", bool) | ...

KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "transport.md"


@dataclass(frozen=True)
class Turn:
    kind: Kind = "openai"
    is_sub: bool = False
    codex_ws: bool = True
    ws_off: bool = False
    has_out: bool = True
    quiet: bool = False

    def case_id(self) -> str:
        seat = "sub" if self.is_sub else "root"
        return (
            f"{self.kind}.{seat}.ws{int(self.codex_ws)}"
            f".off{int(self.ws_off)}.out{int(self.has_out)}.q{int(self.quiet)}"
        )


def eligible(t: Turn) -> bool:
    if t.kind != "responses":
        return False
    if t.is_sub:
        return False
    if not t.codex_ws:
        return False
    if t.ws_off:
        return False
    if not t.has_out:
        return False
    if t.quiet:
        return False
    return True


def pipe(t: Turn) -> Pipe:
    return "ws" if eligible(t) else "sse"


def idle_expired(now: int, used: int, limit: int) -> bool:
    return now - used > limit


def all_turns() -> list[Turn]:
    bits = (False, True)
    return [
        Turn(kind, is_sub, codex_ws, ws_off, has_out, quiet)
        for kind, is_sub, codex_ws, ws_off, has_out, quiet in product(KINDS, bits, bits, bits, bits, bits)
    ]


def step(t: Turn, e: Event) -> Turn:
    k = e[0]
    if k == "setKind":
        return Turn(e[1], t.is_sub, t.codex_ws, t.ws_off, t.has_out, t.quiet)
    if k == "markSub":
        return Turn(t.kind, True, t.codex_ws, t.ws_off, t.has_out, t.quiet)
    if k == "joinRoot":
        return Turn(t.kind, False, t.codex_ws, t.ws_off, t.has_out, t.quiet)
    if k == "setCodexWs":
        return Turn(t.kind, t.is_sub, e[1], t.ws_off, t.has_out, t.quiet)
    if k == "setWsOff":
        return Turn(t.kind, t.is_sub, t.codex_ws, e[1], t.has_out, t.quiet)
    if k == "setHasOut":
        return Turn(t.kind, t.is_sub, t.codex_ws, t.ws_off, e[1], t.quiet)
    if k == "setQuiet":
        return Turn(t.kind, t.is_sub, t.codex_ws, t.ws_off, t.has_out, e[1])
    raise ValueError(f"unknown event {e!r}")


def run(t: Turn, es: list[Event]) -> Turn:
    for e in es:
        t = step(t, e)
    return t


EVENTS: tuple[Event, ...] = (
    ("setKind", "anthropic"),
    ("setKind", "openai"),
    ("setKind", "responses"),
    ("markSub",),
    ("joinRoot",),
    ("setCodexWs", False),
    ("setCodexWs", True),
    ("setWsOff", False),
    ("setWsOff", True),
    ("setHasOut", False),
    ("setHasOut", True),
    ("setQuiet", False),
    ("setQuiet", True),
)


def project(t: Turn) -> str:
    if t.is_sub:
        return "Sub"
    if eligible(t):
        return "Ws"
    if t.kind != "responses":
        return "Sse"
    return "Blocked"


def event_label(e: Event) -> str:
    k = e[0]
    if k == "setKind":
        return f"setKind {e[1]}"
    if k in ("markSub", "joinRoot"):
        return k
    return f"{k} {int(e[1])}"


def walk(start: Turn | None = None) -> list[tuple[Turn, Event, Turn]]:
    src = start or Turn()
    seen = {src}
    q = [src]
    out: list[tuple[Turn, Event, Turn]] = []
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
    lines = ["stateDiagram-v2", "  [*] --> Sse"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: transport\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/Transport.lean`.\n"
        "\n"
        "Process kernel, not a Turing machine: finite `Event` / `step`, no tape.\n"
        "The 96-cell cube is the snapshot. A sub never takes WS; only one cell is\n"
        "WS (a live root Responses turn). PromptCache isolates the child key; this\n"
        "kernel is the pipe that child is forbidden from opening. Shape stays a\n"
        "cube of one observation — fleet topology is not a Shape cell.\n"
        "\n"
        "The diagram is the projection of the live Python `step`. Emit it with\n"
        "`python3 spec/conformance.py --diagram transport`.\n"
        "\n"
        "```mermaid\n"
        f"{body}\n"
        "```\n"
    )


def write_kernel_md(path: Path = KERNEL_MD) -> Path:
    path.write_text(kernel_md())
    return path


def check_diagram() -> None:
    idle = Turn()
    if project(idle) != "Sse" or eligible(idle):
        raise ValueError("diagram: default turn is not Sse")
    ws = step(idle, ("setKind", "responses"))
    if not eligible(ws) or project(ws) != "Ws":
        raise ValueError("diagram: setKind responses did not reach Ws")
    sub = step(ws, ("markSub",))
    if eligible(sub) or project(sub) != "Sub":
        raise ValueError("diagram: markSub did not block WS")
    if eligible(step(sub, ("setKind", "responses"))):
        raise ValueError("diagram: setKind responses granted a sub WS")
    back = step(sub, ("joinRoot",))
    if not eligible(back) or project(back) != "Ws":
        raise ValueError("diagram: joinRoot did not restore Ws")
    if eligible(step(ws, ("setQuiet", True))):
        raise ValueError("diagram: quiet was WS")
    if eligible(step(ws, ("setKind", "anthropic"))):
        raise ValueError("diagram: anthropic was WS")
    if eligible(run(idle, [("markSub",), ("setKind", "responses")])):
        raise ValueError("diagram: sub then responses was WS")
    text = mermaid()
    if "Sse --> Ws: setKind responses" not in text:
        raise ValueError("diagram: mermaid missing Sse setKind responses→Ws")
    if "Ws --> Sub: markSub" not in text:
        raise ValueError("diagram: mermaid missing Ws markSub→Sub")
    if "Sub --> Ws: joinRoot" not in text:
        raise ValueError("diagram: mermaid missing Sub joinRoot→Ws")
    if "Sub --> Ws: setKind responses" in text:
        raise ValueError("diagram: mermaid has Sub setKind responses→Ws")
