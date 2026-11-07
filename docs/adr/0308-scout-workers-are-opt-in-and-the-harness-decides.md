# 0308. Scout workers are opt-in, and the harness decides where they help

Status: accepted 2026-10-30

## Context

A cheaper, faster model can gather context for a stronger root model: the
root asks a read-only `scout` subagent where things are, then does the work
itself. The question was whether graff should route that work by default,
either in graff or behind the hosted gateway's `auto-*` models, to lower the
cost of each task.

Two prerequisites were broken and are fixed alongside this record. A worker
could not be seated on a model only the gateway's live catalog lists
(`--subagent-model` reported it unknown, and a persona's `model:` pin was
resolved against the root's provider and silently ignored). And a worker's
gateway calls were reported as unknown cost, because that catalog was never
loaded unless the root used it.

We then measured the same tasks with and without a scout on a fast gateway
model, under a stronger root model, with checks the agent never saw:

- **Small repository, change tasks** (the files read are the files edited):
  correctness was the same, and a task with the scout cost about 1.6 times
  as much and took about 25% longer. The root still opened every file it
  edited, and the scout's brief rode along in every later root call.
- **Large repository, exploration questions** (find where something lives and
  cite it): the scout raised correctness from 13 to 17 of 18 checks and cut
  the root's own spend by about 12%, but the scout's calls made a task about
  20% more expensive overall and about 60% slower. On the most
  exploration-heavy question the total cost fell slightly, with better
  answers.

Hidden routing has failed us before: an overloaded upstream silently served
another model, which read as a harness regression until it was traced.

## Decision

- A scout is a persona, not a default. A project or user opts in with
  `.harness/agents/scout.md` pinned as `model: <provider>/<model>`; a pin on
  another provider applies only when the session starts with
  `--allow-cross-provider-subagents` and that provider has a login. Without
  either, the trace says why the pin was ignored and the worker keeps the
  session default.
- Startup loads the catalog of any provider workers may be seated on, so
  their models resolve and their calls are priced.
- Whether a repository benefits from a scout is the harness's call, made
  from evidence: the scout persona and the instruction to use it are part of
  the harness tree (`graff harness-tree`), so the refine loop can add, drop,
  or re-pin them per repository from how runs behaved.
- The gateway may choose which model serves a role, but only on request
  (`auto-*`), and it must report the model that actually served each call,
  including after a fallback.

## Consequences

Nothing changes for a user who has not opted in. The scout is worth
offering for exploration-heavy work in large repositories, where it buys
accuracy; it is not a cost lever on small change tasks. A scout should
return a short brief (facts and file:line pointers), since a long one taxes
every later root call. Revisit if a cheaper scout, a shorter brief, or a
reliable signal of how much exploring a task needs makes it a net saving.
