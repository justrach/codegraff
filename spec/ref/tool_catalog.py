"""Executable reference model for the tool-catalog kernel.

Faithful port of spec/lean/Graff/ToolCatalog.lean. The Lean file is the
source of truth; this module exists so the harness runs without lake.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from typing import Iterable

LOCAL_TOOLS = (
    "bash",
    "bash_output",
    "bash_kill",
    "read_file",
    "edit_file",
    "write_file",
    "codedb",
    "read_tool_result",
    "imagegen",
)
LEAN_TOOLS = (
    "attempt_completion",
    "load_tool_schemas",
)
OPTIONAL_TOOLS = ("imagegen",)
BASE_TOOLS = (
    "bash",
    "bash_output",
    "bash_kill",
    "read_file",
    "edit_file",
    "write_file",
    "webfetch",
    "skill",
    "codedb",
    "read_tool_result",
)
META_TOOLS = (
    "todo_write",
    "todo_read",
    "eval",
    "note_constraint",
    "ask_user",
    "attempt_completion",
    "load_tool_schemas",
    "mcp_search_tools",
    "mcp_select_tool",
    "clock_sleep",
)
ROOT_EXTRAS = (
    "subagent",
    "workflow",
    "agent_output",
    "learn_candidate",
    "peer_message",
    "workspace",
)
ROOT_UNIVERSE = BASE_TOOLS + META_TOOLS + ROOT_EXTRAS


@dataclass(frozen=True)
class Flags:
    no_local: bool = False
    lean: bool = False
    imagegen: bool = False
    clock_sleep: bool = False
    learn_loaded: bool = False
    is_sub: bool = False

    def case_id(self) -> str:
        seat = "sub" if self.is_sub else "root"
        return (
            f"{seat}.nl{int(self.no_local)}.lean{int(self.lean)}"
            f".img{int(self.imagegen)}.clk{int(self.clock_sleep)}"
            f".lrn{int(self.learn_loaded)}"
        )


def _keep(names: Iterable[str], pred) -> list[str]:
    return [n for n in names if pred(n)]


def chosen(f: Flags) -> list[str]:
    if f.is_sub:
        return list(BASE_TOOLS)
    return _keep(
        ROOT_UNIVERSE,
        lambda n: not ((not f.clock_sleep and n == "clock_sleep") or (not f.learn_loaded and n == "learn_candidate")),
    )


def with_available(f: Flags, xs: list[str]) -> list[str]:
    return xs + list(OPTIONAL_TOOLS) if f.imagegen else xs


def filter_local(f: Flags, xs: list[str]) -> list[str]:
    if not f.no_local:
        return xs
    local = set(LOCAL_TOOLS)
    return [n for n in xs if n not in local]


def filter_lean(f: Flags, xs: list[str]) -> list[str]:
    if not (f.lean and not f.is_sub):
        return xs
    keep = set(LEAN_TOOLS)
    return [n for n in xs if n in keep]


def catalog(f: Flags) -> list[str]:
    return filter_lean(f, filter_local(f, with_available(f, chosen(f))))


def advertised(f: Flags, name: str) -> bool:
    return name in catalog(f)


def is_optional(name: str) -> bool:
    return name in OPTIONAL_TOOLS


def is_local(name: str) -> bool:
    return name in LOCAL_TOOLS


def blocked(f: Flags, name: str) -> bool:
    return (f.no_local and is_local(name)) or (is_optional(name) and not f.imagegen)


def all_flags() -> list[Flags]:
    bits = (False, True)
    return [
        Flags(*row)
        for row in product(bits, bits, bits, bits, bits, bits)
    ]


def subsequence(inner: list[str], outer: list[str]) -> bool:
    it = iter(outer)
    return all(x in it for x in inner)
