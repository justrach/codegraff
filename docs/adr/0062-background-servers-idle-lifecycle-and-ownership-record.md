# 0062. Background servers have an idle lifecycle and an ownership record

Status: accepted 2026-09-03

## Context

A dev server the model starts with `bash {run_in_background: true}` (or one
that auto-backgrounded after the foreground wait, ADR 0026) keeps running
after the turn, after the user stops looking, and — when the session died
without its defers — after graff itself. #199's postmortem found one such
tree alive for three days, hot on CPU, holding gigabytes and a port, while
the trajectory that started it had reported cleanup complete.

The pool already owned the tree: a job leads its own process group (#198),
`bash_kill` and session end kill the group, a foreground run kills its
descendants even after a normal exit. What was missing was time (nothing
ever ended a forgotten job), a way to keep one on purpose, a record that
outlives the process that wrote it, and a place to see it all.

## Decision

1. **Silence is the idle clock.** Graff cannot see HTTP traffic without a
   proxy, so activity is what it can see: bytes the job writes, a
   `bash_output` read or blocking wait, the foreground wait, a pin. After
   30 minutes of none of these the user gets one dim line naming the stop
   and the pin; after 2 hours the job's whole process group is killed and
   the job stays listed as `idle-stop` with its command kept, so
   `/jobs restart <id>` or a plain rerun brings it back. Both thresholds
   are `GRAFF_JOB_IDLE_WARN_MINS` / `GRAFF_JOB_IDLE_STOP_MINS`; 0 turns a
   step off. The model is told in the tool result and, at its next real step
   boundary, in a notice — never as an idle auto-turn wake (ADR 0061: nobody
   was there for two hours, and a wake would spend a turn telling nobody).

2. **No SIGSTOP "pause".** A stopped process keeps its memory and its port
   and cannot notice a request. Stopped-with-the-command-kept is the honest
   pause; the restart is one command.

3. **`/jobs keep <id>` pins.** A pinned job is exempt from the idle stop and
   is *retained* at session end instead of killed: its stdout/stderr pipes
   are handed to a detached `cat >/dev/null` (so a Node server does not die
   of EPIPE on its next log line when graff's read ends close) and its
   record is rewritten as `retained`. Pinning is a user action; the model
   is told how to ask for it, not given a tool to do it.

4. **One ownership record per job**, `~/.codegraff/jobs/<pid>.json`: leader
   pid **and start identity** (#413), owner session pid and identity,
   command, cwd, start time, pinned/retained. Written at spawn, removed when
   the pump reaps the job, kept when the job is retained. It is what
   survives a hard death of graff.

5. **`graff servers [stop <pid>|prune]`** reads those records from any
   directory: state (running / pinned / retained / gone / unknown), age,
   owner session alive or gone, listening ports (read live via `lsof` by
   process group — a server is not listening yet at spawn, so ports are not
   stored), command, cwd. `stop` signals a group only when the leader still
   carries the recorded start identity; a recycled pid, or one the OS will
   not identify, is never touched. Nothing graff did not start appears here.

## Consequences

* A forgotten silent server costs at most two hours, not three days, and
  the user is told before and after. A server that is being used keeps
  logging and stays up; one that only serves HMR keepalives to a forgotten
  tab logs nothing and stops — which is the intent of #199.
* A job that legitimately runs silent for hours (a long build with no
  output) needs a pin or a raised `GRAFF_JOB_IDLE_STOP_MINS`; the 30-minute
  notice says so.
* Retaining a pinned job leaves two `cat` processes alongside it until it
  exits. Windows has no process groups, no `lsof` and no drainer: records
  are written and listed, `stop` and retain report unsupported there.
* `jobs.zig` moved its `graff worktree` commands to `worktree_cmd.zig` to
  stay under the file cap; callers are unchanged.

## Not decided

A port proxy that wakes a stopped server on the next request. It would
make the pause transparent, at the price of owning the port; revisit if
users pin more servers than they restart.
