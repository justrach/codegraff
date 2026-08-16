"""Executable port of lean-proofs/Graff/PathConfine.lean."""

from __future__ import annotations

from dataclasses import dataclass
from itertools import product
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
