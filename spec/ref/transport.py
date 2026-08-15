"""Executable port of lean-proofs/Graff/Transport.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from typing import Literal

Kind = Literal["anthropic", "openai", "responses"]
Pipe = Literal["ws", "sse"]
KINDS: tuple[Kind, ...] = ("anthropic", "openai", "responses")


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
