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
from ref.prompt_stable import Cell as StableCell
from ref.prompt_stable import EVENTS as STABLE_EVENTS
from ref.prompt_stable import keep as stable_keep
from ref.prompt_stable import land as stable_land
from ref.prompt_stable import run as stable_run
from ref.prompt_stable import hit_ok as stable_hit
from ref.prompt_stable import State as StableState


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


def stable_lines() -> list[str]:
    lines = ["PromptStable  20 cells  5 keep  (OpenGauss must-nots)", ""]
    keeps = 0
    for ev in STABLE_EVENTS:
        k = stable_keep(StableCell(ev, stable_land(ev)))
        if k:
            keeps += 1
        mark = "keep" if k else "bust"
        lines.append(f"  {ev:<20} → {stable_land(ev):<8}  {mark}")
    if keeps != 5:
        raise ValueError(f"showcase: stable keep {keeps}, want 5")
    s = stable_run(StableState(), [
        ("start",),
        ("ev", "turn"),
        ("ev", "skill_inject"),
        ("ev", "schema_load"),
        ("ev", "toolset_append"),
        ("ev", "compact"),
    ])
    if not stable_hit(s):
        raise ValueError("showcase: stable maximizing walk left HIT")
    lines.append("")
    lines.append("  start + turn + skill + schema + append + compact  HIT")
    lines.append("  clock_tick / toolset_rewrite / memory_reload       miss")
    lines.append("  set_system_prompt / standing_change               miss (allowed bust)")
    return lines


def live_lines() -> list[str]:
    return [
        "live Zig  (the impl half)",
        "",
        "  promptCatalog          names + triggers, sorted, no bodies, no file:",
        "  execSkill list/load    do not rewrite the pinned g_skills prefix",
        "  /skills reload         updates the tool list; does not rebuild sys_normal",
        "  buildSystemPrompt      pins the catalog once at session start",
        "  promptCacheKey         sticky per project; child is a suffix",
        "  essay_refresh_turns    0 — standing essay is change-only (ADR 0005)",
        "  tools tail             append-only after the stable head (#476)",
    ]


def verdict() -> str:
    return "verdict: maximizing  (1/6 prefix, 5/20 stable keep, sticky key, join restores)"


def check_maximizing() -> None:
    cube_lines()
    walk_lines()
    cache_lines()
    stable_lines()


def showcase(which: str = "prompt") -> str:
    check_maximizing()
    blocks = {
        "prompt_prefix": [cube_lines(), walk_lines()],
        "prompt_cache": [cache_lines()],
        "prompt_stable": [stable_lines()],
        "prompt": [cube_lines(), walk_lines(), cache_lines(), stable_lines(), live_lines()],
    }
    picked = blocks.get(which)
    if picked is None:
        raise ValueError(
            f"no showcase for {which!r} (try prompt, prompt_prefix, prompt_cache, prompt_stable)"
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
