"""Executable port of lean-proofs/Graff/PathConfine.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from pathlib import Path
from typing import Literal

Identities = Literal["both_empty", "rec_empty", "mine_empty", "same", "differ"]
Probe = Literal["gone", "match", "mismatch", "unknown"]
Verdict = Literal[
    "self",
    "other_worktree",
    "live_foreign",
    "live_unverified",
    "stale_dead",
    "stale_unverifiable",
]
Walk = Literal["empty", "safe", "escaped", "absolute"]
Event = tuple  # ("startAbs",) | ("component", str)

KERNEL_MD = Path(__file__).resolve().parents[1] / "kernels" / "path_confine.md"

PATHS = (
    "",
    "src/main.zig",
    "a/b/c",
    "/etc/passwd",
    "../outside",
    "a/../../b",
    "a/./b",
    ".",
    "foo/..",
    "..",
    "..hidden",
    ".graff/settings.json",
    "a//b",
    "//etc/passwd",
    r"foo\..\bar",
    "foo/bar/baz",
)

EVENTS: tuple[Event, ...] = (("startAbs",), ("component", ".."), ("component", "x"))


def components(path: str) -> list[str]:
    out: list[str] = []
    for part in path.replace("\\", "/").split("/"):
        if part:
            out.append(part)
    return out


def confined(path: str) -> bool:
    if path == "":
        return False
    if path.startswith("/"):
        return False
    return ".." not in components(path)


def prefixes(path: str) -> list[str]:
    acc: list[str] = []
    seen = ""
    for part in path.split("/"):
        if not part:
            continue
        seen = part if not seen else f"{seen}/{part}"
        acc.append(seen)
    return acc


def symlink_safe(path: str, links: list[str]) -> bool:
    linkset = set(links)
    return all(pre not in linkset for pre in prefixes(path))


def file_tool_ok(path: str, links: list[str]) -> bool:
    return confined(path) and symlink_safe(path, links)


def destructive_git_allowed(yolo: bool, sub: bool) -> bool:
    return yolo and not sub


@dataclass(frozen=True)
class Lease:
    identities: Identities = "same"
    start_zero: bool = False
    probe: Probe = "match"
    pid_self: bool = False

    def case_id(self) -> str:
        return f"{self.identities}.z{int(self.start_zero)}.{self.probe}.me{int(self.pid_self)}"


def owner_verdict(l: Lease) -> Verdict:
    if l.identities in ("both_empty", "rec_empty", "mine_empty"):
        return "stale_unverifiable"
    if l.identities == "differ":
        return "other_worktree"
    if l.start_zero:
        return "stale_unverifiable"
    if l.probe == "gone":
        return "stale_dead"
    if l.probe == "mismatch":
        return "stale_dead"
    if l.pid_self:
        return "self"
    if l.probe == "unknown":
        return "live_unverified"
    return "live_foreign"


def warns(v: Verdict) -> bool:
    return v in ("live_foreign", "live_unverified")


def all_leases() -> list[Lease]:
    return [
        Lease(ident, zero, probe, me)
        for ident, zero, probe, me in product(
            ("both_empty", "rec_empty", "mine_empty", "same", "differ"),
            (False, True),
            ("gone", "match", "mismatch", "unknown"),
            (False, True),
        )
    ]


@dataclass(frozen=True)
class WalkState:
    walk: Walk = "empty"


def step(s: WalkState, e: Event) -> WalkState:
    if e[0] == "startAbs":
        return WalkState("absolute") if s.walk == "empty" else s
    c = e[1]
    if s.walk in ("absolute", "escaped"):
        return s
    if c == "..":
        return WalkState("escaped")
    return WalkState("safe")


def run(s: WalkState, es: list[Event]) -> WalkState:
    for e in es:
        s = step(s, e)
    return s


def confined_walk(s: WalkState) -> bool:
    return s.walk == "safe"


def events_of(path: str) -> list[Event]:
    evs: list[Event] = [("startAbs",)] if path.startswith("/") else []
    evs.extend(("component", c) for c in components(path))
    return evs


def walk_path(path: str) -> WalkState:
    return run(WalkState(), events_of(path))


def project(s: WalkState) -> str:
    return {"empty": "Empty", "safe": "Safe", "escaped": "Escaped", "absolute": "Absolute"}[s.walk]


def event_label(e: Event) -> str:
    if e[0] == "startAbs":
        return "startAbs"
    if e[1] == "..":
        return "component .."
    return "component"


def walk(start: WalkState | None = None) -> list[tuple[WalkState, Event, WalkState]]:
    src = start or WalkState()
    seen = {src}
    q = [src]
    out: list[tuple[WalkState, Event, WalkState]] = []
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
    lines = ["stateDiagram-v2", "  [*] --> Empty"]
    for a, lab, b in diagram_edges():
        lines.append(f"  {a} --> {b}: {lab}")
    return "\n".join(lines) + "\n"


def kernel_md() -> str:
    body = mermaid().rstrip()
    return (
        "# Kernel: path confine / lease\n"
        "\n"
        "Source of truth: `lean-proofs/Graff/PathConfine.lean`.\n"
        "\n"
        "Process kernel, not a Turing machine: finite `Event` / `step`, no tape.\n"
        "A file-tool path is a walk over components. Empty / Safe / Escaped /\n"
        "Absolute. Escaped and Absolute absorb — a subagent does not recover a\n"
        "jail break by taking another component. The 16 lexical paths + 80 lease\n"
        "cells are the snapshot. `--yolo` does not free a sub. Fleet topology is\n"
        "not a Shape cell; Shape stays the observation ladder of one turn.\n"
        "\n"
        "The diagram is the projection of the live Python `step`. Emit it with\n"
        "`python3 spec/conformance.py --diagram path_confine`.\n"
        "\n"
        "```mermaid\n"
        f"{body}\n"
        "```\n"
    )


def write_kernel_md(path: Path = KERNEL_MD) -> Path:
    path.write_text(kernel_md())
    return path


def check_diagram() -> None:
    if walk_path("").walk != "empty":
        raise ValueError("diagram: empty path not Empty")
    if walk_path("src/main.zig").walk != "safe":
        raise ValueError("diagram: src/main.zig not Safe")
    if walk_path("/etc/passwd").walk != "absolute":
        raise ValueError("diagram: /etc/passwd not Absolute")
    if walk_path("../outside").walk != "escaped":
        raise ValueError("diagram: ../outside not Escaped")
    if step(walk_path("../outside"), ("component", "src")).walk != "escaped":
        raise ValueError("diagram: escaped did not absorb")
    if step(walk_path("/etc/passwd"), ("component", "..")).walk != "absolute":
        raise ValueError("diagram: absolute did not absorb")
    for p in PATHS:
        if confined(p) != confined_walk(walk_path(p)):
            raise ValueError(f"diagram: walk disagrees on {p!r}")
    text = mermaid()
    if "Empty --> Safe: component" not in text:
        raise ValueError("diagram: mermaid missing Empty component→Safe")
    if "Safe --> Escaped: component .." not in text:
        raise ValueError("diagram: mermaid missing Safe component ..→Escaped")
    if "Empty --> Absolute: startAbs" not in text:
        raise ValueError("diagram: mermaid missing Empty startAbs→Absolute")
    if "Escaped --> Safe: component" in text:
        raise ValueError("diagram: mermaid has escape recovery")
    if "Escaped --> Absolute: startAbs" in text:
        raise ValueError("diagram: mermaid has mid-walk startAbs")
    if "Safe --> Absolute: startAbs" in text:
        raise ValueError("diagram: mermaid has mid-walk startAbs from Safe")
