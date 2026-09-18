# Working with goals

Graff keeps one current goal per session. `/goal <objective>` starts work and
tracks its checklist; an optional duration such as `/goal 30m <objective>`
paces the autonomous run. A duration is checked between turns, so a tool or
turn already running may finish after that time.

- `/goal` or `/goals`: inspect the current goal without changing it.
- `/goal pause`: stop goal steering.
- `/goal resume`: enable goal steering again.
- `/goal clear`: remove the objective and park its checklist.
- `/todo`: inspect the task list.

`/goals` is always read-only, including when followed by text. Use `/goal`
to make changes. It lists the current goal, not a queue of saved objectives.
Commands such as `/goalkeeper` do not match `/goal`.

A typed goal is a task that can complete. The `--goal` launch flag instead
sets standing policy that remains until the user pauses or clears it.
Compaction preserves that distinction along with active, paused, or complete
status. Paused and completed objectives remain reference material; a summary
does not authorize starting them again.

## Comparison with fx

The fx source reviewed at
[`71af79f`](https://github.com/vercel-labs/fx/tree/71af79f2603b993725926cec609ced445dbb68ef)
has no `/goal` or `/goals` command in its built-in catalog. Its relevant design
is continuity through active-turn steering and context compaction. Its
[compaction handoff](https://github.com/vercel-labs/fx/blob/71af79f2603b993725926cec609ced445dbb68ef/src/core/agent/runtime/context_compaction_state.zig)
explicitly separates summary prose from authorization. Graff applies that
principle to its own richer goal lifecycle; it does not import an fx goal API.

## Local regression evals

These exercise the real harness with a local scripted model and no paid calls:

```sh
zig build
python3 scripts/eval-tier2.py --only goal-paused-survives-compaction --only goal-complete-survives-compaction
```

The evals restore an inactive goal, compact the conversation, and inspect the
next model request for the preserved status and the instruction not to restart
the objective. They test harness behavior, not a model's willingness to obey.
