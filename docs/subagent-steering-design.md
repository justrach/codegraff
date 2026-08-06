# Subagent steering: merged design for #417 and #392

Status: design, not implemented. Supersedes the separate proposals in #417
(retained, addressable subagents with parent-child steer messaging) and #392
(resumable workers + two-tier steering). Read alongside #393, which supplies
the containment rules this design must not violate.

## Why these two issues have to merge

They describe one mechanism from two directions. #417 approaches it from
addressability (a durable child registry, children reachable by name, messages
that steer a running child). #392 approaches it from resumption (a task id
returned by spawn, a follow-up that continues the same worker rather than
re-briefing a fresh one, and a queue-versus-trigger split on the steering
call). Neither is implementable without most of the other: resumption needs an
identity that outlives the spawn, and addressing needs somewhere for a
completed child's state to live.

Built separately they would produce two id schemes, two registries, and two
message paths. The repo already carries the cost of that pattern once, see
"Two id schemes today" below.

## What actually exists today (verified against the source, 2026-08-06)

This matters because one of the two issues rests on a premise that is false.

**Background spawns already have identity and a registry.** `subagent.zig`
carries `AgentJob` and `g_agent_jobs`: a stable incrementing `u32` id, a
session-global mutex-guarded list, non-blocking spawn on `io.concurrent`, and
non-destructive polling through the `agent_output` tool. `run_in_background:
true` hands the model that id immediately. The admission counter is
deliberately independent of `RunBudget.active` to avoid a starvation deadlock,
and that reasoning applies unchanged to anything this design adds.

**But that registry is in memory only.** It dies with the process. The id is a
process-local counter, so it is not stable across a resume and cannot address
anything after restart.

**What persists per subagent is an inspection artifact, not a session.**
`cards.zig:writeSubagentDetail` writes `.graff/subagents/<id>.md` containing
id, label, kind, status, elapsed_ms, tools, the task prompt, and the final
report. There is no message history, no tool-call record, no provider state.

> **Correction to #392.** That issue states the worker's "transcript already
> persists under `.graff/subagents/`, so this is plumbing, not new state."
> That is not the case. Only the final report persists, as markdown. Resuming
> a worker "with its accumulated context" requires persisting the worker's
> actual message history, which is currently discarded when the pool thread
> finishes. #392 is therefore materially larger than its own estimate, and the
> history-persistence prerequisite is the first slice, not an afterthought.

**Two id schemes today.** `cards.zig:subagentId` produces
`sa-<3-digit ordinal>-<8 hex>`, stable across runs for the same
label+prompt+ordinal, and used for inspect links. Background jobs use the
`u32` counter. These name the same conceptual thing and must be unified before
either issue is built, or the registry will key on one and the artifacts on
the other.

**Depth is already contained.** Subagents cannot spawn subagents: `execSubagent`
gates on `from_sub`, returning "subagents cannot spawn subagents". #393's depth
cap is therefore partly enforced already, and this design must not open a hole
in it (see Containment).

## The collision with #441

#441 (append-only per-session transcript) explicitly **excludes subagents**, on
the stated grounds that their history is "never persisted by design". #392 and
#417 require exactly that history to exist.

These are not reconcilable by picking a side, because both defaults are right
for their case. A fire-and-forget worker's context is genuinely disposable, and
persisting every fan-out worker's full history by default would be a
significant and unrequested disk and privacy cost. A worker the parent intends
to steer or resume must retain history or the feature is meaningless.

**Resolution: retention is opt-in per spawn.** The `subagent` tool gains
`retained: true`. Only retained workers get a transcript under the #441
mechanism. #441 keeps its exclusion as the default and gains one documented
exception rather than an unconditional reversal. Unretained workers keep
exactly today's behavior, byte for byte.

This also gives the model a real cost signal: retention is a choice with a
price, made at spawn time when the parent knows whether a follow-up is likely.

## The merged design

### Identity

One scheme. The `sa-<ordinal>-<hash>` form wins, because it is already stable
across runs and already appears in persisted artifacts and inspect links. The
background-job `u32` becomes an internal index into the in-memory registry, not
an identity the model ever sees. Every id the model receives, from a foreground
spawn, a background spawn, or a resume, is the `sa-` form.

Names from #417 are an **alias, never the identity**. A model-chosen name
resolves to an id within the family scope. Identity itself stays
harness-assigned, which preserves #417's own requirement that sender identity
is never model-supplied.

### Registry

One append-only JSONL per parent session, last-write-wins on replay, tombstones
on delete, following #417's shape. It records id, name alias, status, the
worker's transcript ref, and the spawn parameters needed to rehydrate. It lives
under the parent's session directory and shares the session lifecycle and sweep
that #409 established, the same lifecycle #441 follows. No second cleanup path.

### Steering: one primitive, one flag

#392's Codex-derived split (`send_message` queues only; `followup_task` queues
and triggers a turn) and #417's "steer a running child's turn" unify into a
single delivery call with a `trigger` boolean:

| child state | `trigger: false` | `trigger: true` |
|---|---|---|
| running | queued into the child's next turn, no extra turn cost | queued; already turning, so identical to `false` |
| idle, retained | queued, sits until something triggers | rehydrate from registry, deliver, run a turn |
| completed, unretained | rejected with an actionable error | rejected with an actionable error |

The `trigger: false` path against a running child is the cheap nudge #392 wants,
and the queue-not-await delivery #417 requires. Collapsing to one tool with a
flag beats two tools because the expensive case is then visibly the exception.

**Delivery is queued and never awaited.** This is the hard invariant from #417:
mutual sends between two busy agents must not deadlock. It composes with the
existing admission design, whose comment already documents why holding an outer
slot across a child's lifetime deadlocks. Steering must not introduce a wait
that reproduces that bug.

### Rehydration

Messaging a completed retained child reconstructs its session from the
transcript plus the registry row, then runs one turn. This is where the #441
mechanism earns its second use: the transcript is the rehydration source, not
just a grep target.

### Containment (#393)

Retention and steering must not become a hole in the depth cap:

- A retained child is still a child. It cannot spawn or steer, so no cycles.
- Steering is family-scoped: parent to child, and siblings only within one
  parent. No addressing across session boundaries.
- Size limits per message and a small rate bucket per (sender, recipient) pair,
  per #417.
- A resumed worker draws from the same #390 budget ledger as the original
  spawn. It is the same worker continuing, not a new allocation.

## Slices

1. **Persist retained worker history.** Add `retained: true` to the `subagent`
   tool; route those workers through #441's transcript writer. Nothing
   addressable yet. This is #392's real prerequisite and the honest first
   slice.
2. **Unify identity and add the durable registry.** Collapse the two id schemes
   onto `sa-`, write the append-only registry, expose `subagent_list`.
3. **Steering.** One delivery call with `trigger`, queued and never awaited,
   running children only.
4. **Rehydration.** Completed retained children resume from transcript, which
   turns on the idle and completed rows of the table above.

Slices 1 and 2 are worth doing even if 3 and 4 are never built: they make
worker output durable and inspectable, which the trajectory and #419 overview
work both want independently.

## Open questions

- Retention default for workflow workers specifically. They are the most
  numerous spawns and the least likely to be steered, so the default should
  probably stay off even when a parent sets retention for direct spawns.
- Transcript size cap for workers, which should likely be tighter than a root
  session's, given fan-out multiplies it.
- Whether a tombstoned child's transcript is deleted immediately or swept with
  the session. Immediate deletion is better for privacy, worse for postmortem.
