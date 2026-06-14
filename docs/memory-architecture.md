# Memory architecture — a first-class, evolvable memory layer

A design for pulling memory **into graff's core** as a pluggable, evolvable
layer — rather than leaving it scattered across history/compaction/sessions or
bolted on as an external MCP. Companion to
[hyperagents.md](hyperagents.md) (the DGM/MAP-Elites evolution loop) and
[architecture.md](../architecture.md) (the harness internals + perf budgets).

Framing borrowed from **ALMA** (Automated meta-Learning of Memory designs for
Agentic systems, [arXiv:2602.07755](https://arxiv.org/abs/2602.07755)): the
statelessness of foundation models is the bottleneck for long-horizon, multi-turn
work — which is becoming the norm — and a memory module's *Design* (schema +
retrieval + update) is itself something you can search and evolve, not hand-craft
once. graff's `engram` companion is already an ALMA-style layer; this doc makes a
minimal memory layer native, with engram as one backend among several.

## 0. Two memories — don't conflate them

| | **task / experience memory** (this doc) | **evolutionary memory** ([hyperagents.md](hyperagents.md)) |
|---|---|---|
| purpose | solve the current & future *tasks* better | improve the *agent itself* over generations |
| unit | an episode / fact / note | a genome (prompt + tools + memory design) + its fitness |
| store | `.harness/memory/` (this doc) | `harness.trajectory.jsonl` + `harness_scores` |
| lifetime | reused across turns/sessions/projects | append-only archive, fleet-aggregated |

They interact (the memory Design is a *slot in the genome* — §8), but they are
different stores with different write paths. This doc is about the first.

## 1. The hard constraint: memory is append-only context, never prefix mutation

graff is built to keep the prompt prefix cacheable — stable system prompt,
strictly append-only history, comptime-frozen tool order, an explicit Anthropic
`cache_control` breakpoint (see architecture.md). **A memory layer that injects
retrieved context at the *front* of the prompt invalidates the KV-cache every
turn** — the exact failure mode `set_system_prompt` is warned about.

So the invariant is structural:

> Retrieved memory enters the conversation as **append-only** content (a tool
> result or a user-turn appendage), never by editing the cached prefix.

Corollary — **prefer model-pulled recall over framework-pushed injection.** A
`recall` *tool* the model calls when it wants context keeps the prefix frozen and
puts the "when to remember" decision where it belongs (with the model). Pushed
pre-turn injection is allowed only for the cheapest design (a fixed scratchpad
block) and only when it sits *after* the cached prefix.

## 2. The MemoryDesign interface — the evolvable unit (ALMA's "Design")

One narrow interface, three ops. The Design is fingerprinted (`memory_sha`) the
same way a system prompt is (`prompt_sha`), so it becomes a genome slot the
fleet can evolve. Proposed Zig shape (a tagged union of built-ins + an MCP
escape hatch keeps it zero-dep by default):

```zig
const MemoryDesign = struct {
    name: []const u8,         // "scratchpad" | "episodic" | "structured" | "engram"
    sha: [16]u8,              // fingerprint of the design's config/code → genome slot
    scope: Scope,             // session | project | user | fleet  (§6)
    vtable: *const VTable,

    const VTable = struct {
        /// Pull up to k memories relevant to `query`. Returns text to append
        /// to history as a tool result — NEVER spliced into the prefix (§1).
        retrieve: *const fn (self: *anyopaque, gpa: Allocator, query: []const u8, k: usize) []const u8,
        /// Persist one experience (a fact, an episode, a tool-sequence outcome).
        update: *const fn (self: *anyopaque, gpa: Allocator, experience: Experience) void,
        /// Optional: a deterministic self-eval for ALMA scoring (§8).
        eval: ?*const fn (self: *anyopaque) f64 = null,
    };
};
```

`retrieve`/`update` are the only surfaces the agent loop touches; everything
else (schema, retrieval policy, eviction) lives behind the Design.

## 3. Built-in designs (ship a default; the rest are variations)

Ordered cheapest → richest. All are file-backed under `.harness/memory/`
(path-confined, §9) so the zero-dep, filesystem-as-context ethos (the Manus
lesson graff already follows for the trace/trajectory files) holds with no new
dependency.

- **`null`** — today's behavior; no memory. Always available, zero cost.
- **`scratchpad`** — one notes file the agent reads at session start and rewrites
  via a `note` tool. Pure recitation: re-stating the goal/subgoals to fight
  long-horizon drift. The only design allowed pushed (append-only) injection.
- **`episodic`** — append `{task, key actions, tool-seq, outcome}` to
  `.harness/memory/episodes.jsonl`; `recall` retrieves by recency + tag/keyword.
  Cheap, deterministic, and the join target for tool-sequence mining
  (hyperagents.md §5).
- **`structured`** — the ALMA "DB schema" design: typed records + explicit
  retrieve/update logic (e.g. a small SQLite or a schema'd JSON index). The
  search space ALMA's Meta Agent ranges over.
- **`engram`** — semantic recall via the `engram` MCP server (ALMA-style over
  codedb). Auto-detected and used if present, exactly like the codedb/muonry
  auto-connect pattern; opt-out in `.harness/settings.json`.
- **`summary-tree`** — compaction output *is* memory: each compaction summary
  becomes a retrievable node, so the existing 80%-window compaction stops being
  a lossy reset and becomes a hierarchical episodic store.

## 4. Where it plugs into the loop

```
session start ─→ scratchpad block appended once (after the cached prefix)
     │
   turn:  model may call  recall("...")  ──▶ Design.retrieve → tool result (append-only)
     │                    note("...")    ──▶ Design.update
     ▼
  compaction (80% window or /compact):
     summary ──▶ Design.update   (compaction = a memory write, not just a reset)
     │
  turn end:  optional post-turn distill ──▶ Design.update (episode + tool-seq + outcome)
```

`recall`/`note` are meta-tools (handled inline, like `todo_write`), so they
never hit the pool threads and never escape the cwd. Compaction and session
`/save` become memory writes rather than one-off operations.

## 5. Scope — the main "variation" axis

The same interface, four scopes; a Design declares which it wants:

| scope | store | reused across | risk |
|---|---|---|---|
| `session` | arena (ephemeral) | turns in one run | none |
| `project` | `.harness/memory/` (cwd) | sessions in a repo | local only |
| `user` | `~/.simple-harness/memory/` | all the user's repos | local only |
| `fleet` | shared, **evolved** Design shipped to all | everyone | code-exec gate (§9) |

Project scope is the default sweet spot: it survives `/save`·`/resume`, it's
path-confined, and it never leaves the machine. Fleet scope is where ALMA meets
the federated loop — and the only one with a real threat model.

## 6. Storage substrate — zero-dep default, MCP upgrade

Mirrors how graff already treats code intelligence (built-in `codedb` tool +
optional `muonry` MCP upgrade): a **file-backed default that needs nothing
installed**, and an **optional semantic backend (`engram`) auto-detected on
PATH**. The Design abstracts the substrate, so `recall`/`note` are identical
whether memory is a JSONL file or an engram vector index. No vector DB is ever
*baked into* the 1.7 MB binary.

## 7. Evolving the memory layer (ALMA × the fleet)

The Design's `memory_sha` is the third genome slot beside the persona prompt and
the tool grant (hyperagents.md §10). Evolution is **coordinate-ascent**, not
joint search:

```
per niche, each generation:
  Phase P (DGM):   mutate persona,  memory+tools fixed  → score on long-horizon suite
  Phase M (ALMA):  memory = engram_search(Designs, eval=engram_eval),  persona fixed
  promote the genome that wins its cell (signed, K-install floor)
```

`engram` already *is* the Phase-M Meta Agent (`engram_eval` scores a Design,
`engram_search` is the ALMA meta-search) — graff supplies the long-horizon
fitness, the signed score (now carrying `memory_sha`), and the federated
promotion. Memory designs only differentiate on **multi-episode** tasks where
reuse pays, so they're evaluated on the long-horizon eval class with outcome-only
credit (no per-turn RL) and efficiency (turns/tokens-to-goal) as half the score.

## 8. Threat model & invariants

1. **KV-cache (§1):** memory is append-only; the cached prefix is never mutated.
2. **Path confinement:** all memory writes stay under `.harness/memory/` (cwd) or
   `~/.simple-harness/memory/` — structural, not bypassed by `/yolo`; subagents
   stay cwd-locked.
3. **Nothing private leaves the machine:** project/user memory is local-only.
   Only at `fleet` scope does anything transmit — and then **only the Design
   (schema/code) + signed scores, never stored task content.**
4. **Code-execution gate (the hard one):** a persona is inert text; an evolved
   memory Design is *code that runs*. Fleet promotion of a Design therefore can
   **not** be the auto-over-millions-of-traces path used for prompts — it
   requires sandboxed eval, deterministic re-check, and a curated/human gate.
   Two-tier promotion: prompts/tool-grants auto; **memory-design code gated.**

## 9. What ships first vs later

- **First (scaffold):** the `MemoryDesign` interface; the `null`, `scratchpad`,
  and `episodic` built-ins; the `recall`/`note` meta-tools; `project` scope under
  `.harness/memory/`; compaction-as-memory-write. All file-backed, zero new deps.
- **Later:** `structured` + `summary-tree` designs; the `engram` backend bridge;
  `user`/`fleet` scope; and fleet-evolved Designs behind the code-exec gate (§8).

The minimal version is small — a meta-tool pair + a JSONL episode store + a
session-start scratchpad — and it immediately makes long-horizon runs less
amnesiac without touching the hot path or the KV-cache.
```

