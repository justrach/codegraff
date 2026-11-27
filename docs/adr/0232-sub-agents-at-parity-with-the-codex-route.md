# 0232. Sub-agents at parity with the codex route, and a suite that measures them

Status: accepted 2026-10-01

## Context

The eval tree had no task that asked for sub-agents, so delegation was never
measured against another harness. The `subagents` suite now has five: three
packages fixed in parallel, a census of four services' logs, an API rename
across three packages, a coverage merge of two inventories, and a docs
sidecar beside a fix. `subagents-solo` is the same five without the
delegation wording, so a run can say whether its children paid for
themselves. Fixtures are git repos with held-out checks. `subagent_split.py`
splits a run into parent time and child time.

Run against the Codex app server on the same model, graff lost three of the
five, and the transcripts showed why:

- **A new file in a new directory.** `write_file` refused it, and the docs
  child generated its whole reference a second time after a `mkdir`.
- **A checklist nobody reads.** In `-p` and piped sessions the prompt still
  said to track work with `todo_write`, so the model loaded the folded tool
  and spent several calls keeping a list no one watched.
- **A wait per child.** `agent_output` took one id, so collecting three
  children cost three model calls.
- **A read-only child that could not compute.** A brief that said "read-only"
  made the child informational (#1360), and its shell then took only an
  allowlist of simple commands: no python, awk, gzip or pipes. Four census
  children reported partial counts, and the parent redid their work.
- **Copying a script's output.** The prompt said to use `write_file` for new
  files, so a script that computed a report printed it, and the model typed it
  back into `write_file` in another call.

The codex route's own client starts each child with its parent's
conversation and runs it at its parent's effort. A graff child started from
the brief alone, at the worker default effort, so an effort set with
`/effort` or chosen by Jev never reached it.

## Decision

- `write_file` creates the missing directory of a new file and says so in
  its result. A path through an existing file still fails.
- With no human attached (`-p`, or a piped session outside `--json` and ACP)
  the system prompt leaves out the two `todo_write` nudges. The tool stays
  loadable, and a standing goal still asks for its checklist.
  `ask_user.detectNoHuman` decides this before the prompt is composed.
- `agent_output` takes `ids` in place of `id` and returns every report in one
  result, waiting for all of them when `wait_ms > 0`. A spawn receipt names
  every child of the session still running, so the model can copy one call.
- A fresh child's first message carries the user's prompts from its parent's
  history, oldest first, newest kept past 8 KiB, ahead of its own task, so
  siblings share that prefix. Notices and tool results are not prompts. A
  resumed worker does not get them again.
- A child without a spawn or persona effort pin runs at its parent's live
  effort, when the child's model accepts that level. On the codex route an
  unset effort already means the catalog default (ADR 0226).
- A `subagent` call can request a `service_tier` for its child. A `workflow`
  call can set it for every worker, including retries. Unspecified workers
  and internal judges use standard service. The resolved worker route must
  offer the requested tier. Retained workers keep their selection on resume.
- A child can also ask Jev mid-run. While Jev serves the child's own seat,
  its catalog carries `jev_effort` (eager on Responses), and a selection
  lands in the child's own pending slot and applies at the child's next
  request. It moves neither its root's effort nor the session's saved
  effort: `jev_effort_state.apply` saves only for the root. Jev's
  session-long circuit is shared, so one failed attempt by any agent
  stops the rest.
- On macOS a read-only child's foreground shell runs under seatbelt
  (`/usr/bin/sandbox-exec`): any command may run and read, writes inside the
  project and all network access are refused, and the gate admits the
  command because the sandbox enforces it. A background command, or any
  command where there is no sandbox, still has to clear the allowlist. If
  the sandbox cannot be set up, a command outside the allowlist is refused,
  never run unsandboxed.
- Each finished child writes one `subagent` trace line with its duration,
  tool calls, context, cached tokens and effort.
- The prompt says a script that computes a file's content writes that file
  itself.

Not adopted: the codex route forks the parent's history under the parent's
own instructions and tools, which shares the parent's cached prefix. A graff
child keeps its own smaller prompt and catalog, which its siblings already
share. Nor resident-thread eviction: graff frees a child's conversation when
the child finishes and keeps only its report, and a run with four children
stayed an order of magnitude below the Codex app server process in resident
memory.

## Consequences

An unpinned child of a session at `/effort high` now reasons at high too.
A child that asks Jev pays for that call like its root does.
A child sees the user's request, so a brief can be shorter, and a child can
also be tempted past its own task; its prompt and the context header both
say to do only its part. A `-p` run that would have kept a checklist no
longer does unless a goal asks for one.

A read-only child on macOS can now run anything that does not write to the
project or the network, so a long computation or a large read is its own
cost, not a refusal. Writes outside the project, to temporary paths, are
allowed.

Revisit the 8 KiB context cap if long sessions crowd a child's first
request, and the effort inheritance if children of high-effort sessions cost
more than the work they save.
