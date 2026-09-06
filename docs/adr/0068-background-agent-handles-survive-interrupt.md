# 0068. Background-agent handles survive an interrupted parent turn

Status: accepted 2026-09-06

## Context

`subagent {run_in_background:true}` returns a numeric handle from a
process-global pump table (`g_agent_jobs`). That table is gone after a
recoverable API interruption that kills or respawns the process (ACP
`-32603`, native `reader.cancel()` raising `session/cancel`, a panic on a
bad envelope). `#753` then saw `agent_output` answer every issued id with
"no background agent — it may never have started", which is false: the
launches succeeded.

The live table cannot be reattached across a process boundary. The
*record* of what we issued can.

## Decision

* Every issued handle is written to a session ledger (`subagent_ledger.zig`)
  and saved with the conversation (`background_agents` in the session file).
* `agent_output` that misses the live table consults the ledger: a finished
  row replays the report; a still-running row from a dead process is named
  as interrupted, never as "never started".
* An ACP API error is a failed turn: save the session (including the
  ledger) and return the error text. Do not exit the ACP loop. A completed
  prompt stream must not send `session/cancel` on reader cleanup.

## Consequences

* Continuation after an interrupt can poll the same ids. Running children
  that died with the process cannot resume; the model is told to re-launch.
* Session files grow a small optional array. Older builds ignore the field.
