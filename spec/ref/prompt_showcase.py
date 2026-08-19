"""Showcase: do the prompt-cache kernels actually maximize?

PromptCache is the key (who emits it, spawn/join). PromptPrefix is the
bytes under that key. Together they are the conditions that keep the old
prompt an exact prefix of the new one. Provider HIT tokens stay a
never-kernel — this file prints the walk, not a bill.
"""

from __future__ import annotations

from ref.prompt_cache import State as CacheState
from ref.prompt_cache import run as cache_run
from ref.prompt_cache import step as cache_step
from ref.prompt_prefix import CATALOGS, PINS, Cell, State
from ref.prompt_prefix import all_cells, cacheable, hit_ok, run, step


MAX_EVENTS: list[tuple] = (
    ("start", "names_only"),
    ("skill_load",),
    ("skill_list",),
    ("rescan",),
    ("turn",),
)


def _mark(ok: bool) -> str:
    return "HIT" if ok else "miss"


def cube_lines() -> list[str]:
    lines = ["PromptPrefix  6 cells  1 HIT  (catalog × pin)", ""]
    head = f"  {'catalog':<14} {'once':<8} {'every_rebuild'}"
    lines.append(head)
    lines.append("  " + "-" * (len(head) - 2))
    for cat in CATALOGS:
        once = _mark(cacheable(Cell(cat, "once")))
        every = _mark(cacheable(Cell(cat, "every_rebuild")))
        note = "  ← measured" if cat == "names_only" else ""
        if cat == "with_paths":
            note = "  ← Codex file: paths"
        lines.append(f"  {cat:<14} {once:<8} {every}{note}")
    hits = sum(1 for c in all_cells() if cacheable(c))
    if hits != 1:
        raise ValueError(f"showcase: hit cells {hits}, want 1")
    return lines


def walk_lines() -> list[str]:
    lines = ["maximizing walk  (live session)", ""]
    s = State()
    for e in MAX_EVENTS:
        s = step(s, e)
        lab = e[0] if e[0] != "start" else f"start {e[1]}"
        ok = hit_ok(s)
        lines.append(
            f"  {lab:<22} frozen={int(s.prefix_frozen)}  "
            f"catalog={s.catalog:<12}  {_mark(ok)}"
        )
        if not ok:
            raise ValueError(f"showcase: {lab} left the HIT cell")
    same = run(s, [("rebuild_into_prefix", "names_only")])
    if not hit_ok(same):
        raise ValueError("showcase: same-catalog rebuild busted")
    lines.append(
        f"  {'rebuild names_only':<22} frozen={int(same.prefix_frozen)}  "
        f"catalog={same.catalog:<12}  HIT"
    )
    bust = run(s, [("rebuild_into_prefix", "with_paths")])
    if hit_ok(bust):
        raise ValueError("showcase: path rebuild stayed HIT")
    lines.append(
        f"  {'rebuild with_paths':<22} frozen={int(bust.prefix_frozen)}  "
        f"catalog={bust.catalog:<12}  miss  (bust)"
    )
    return lines


def cache_lines() -> list[str]:
    idle = CacheState()
    child = cache_step(idle, ("spawn", False, "worktree"))
    if child.partition != "child" or child.seat != "sub":
        raise ValueError("showcase: spawn did not isolate")
    if cache_step(child, ("spawn", True, "shared_cwd")) != child:
        raise ValueError("showcase: sub spawned")
    back = cache_step(child, ("join",))
    if back.partition != "root" or back.label != "main":
        raise ValueError("showcase: join lost the root key")
    if cache_run(idle, [("spawn", False, "shared_cwd"), ("join",)]).partition != "root":
        raise ValueError("showcase: spawn+join lost the root key")
    return [
        "PromptCache  48 cells  32 emit key  24 spawn_ok",
        "",
        "  openai/responses emit prompt_cache_key; anthropic does not",
        "  label=main → root partition; isolation does not mint a key",
        "  spawn isolates the child; sub never spawns; join restores root",
        "  turn is identity (sticky key)",
        "",
        "  Root --spawn--> Child --join--> Root   (root key restored)",
        "  Child --spawn--> Child                 (no second partition)",
    ]


def live_lines() -> list[str]:
    return [
        "live Zig  (the impl half)",
        "",
        "  promptCatalog          names + triggers, sorted, no bodies, no file:",
        "  execSkill list/load    do not rewrite the pinned g_skills prefix",
        "  /skills reload         updates the tool list; does not rebuild sys_normal",
        "  buildSystemPrompt      pins the catalog once at session start",
        "  promptCacheKey         sticky per project; child is a suffix",
    ]


def verdict() -> str:
    return "verdict: maximizing  (1/6 prefix cells, sticky key, join restores)"


def check_maximizing() -> None:
    cube_lines()
    walk_lines()
    cache_lines()


def showcase(which: str = "prompt") -> str:
    check_maximizing()
    blocks = {
        "prompt_prefix": [cube_lines(), walk_lines()],
        "prompt_cache": [cache_lines()],
        "prompt": [cube_lines(), walk_lines(), cache_lines(), live_lines()],
    }
    picked = blocks.get(which)
    if picked is None:
        raise ValueError(
            f"no showcase for {which!r} (try prompt, prompt_prefix, prompt_cache)"
        )
    lines = [
        "prompt-cache max",
        "================",
        "kernels prove the conditions that maximize cache",
        "(stable key + frozen names-only prefix).",
        "provider HIT tokens are a never-kernel.",
        "",
    ]
    for i, block in enumerate(picked):
        if i:
            lines.append("")
        lines.extend(block)
    lines.append("")
    lines.append(verdict())
    lines.append("")
    return "\n".join(lines)
