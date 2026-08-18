# 0004. Peer speech is a working set, not the conversation

Status: accepted 2026-08-18

## Context

#469 injects co-resident speech into history as `role: user` (`[peer message
from …]`, plus a presence roster). Each `deliverInbound` **appends** another
blob that lives until generic compaction. Compaction then treats those blobs
as the human: `cleanUserTurn` is true, so `recentContextStart` will keep the
peer firehose in the ~8k verbatim suffix and summarize the real prompt away,
and `emergencyCutIndex` can restart the conversation on a coordination ping.

That is already a measured failure. `-p` one-shots seek the room to its tail
because ~4k tokens of stale chatter on the first step made ephemeral workers
*answer old messages*. Interactive sessions still dump up to 10 backlog lines
into history (the REPL only *shows* 2).

Surgically deleting those lines from live history is also wrong: it busts the
prompt-cache prefix, rewrites inbound the model already answered, and can eat
a trailing unreplied inject if compact runs between drain and reply. The
append-only JSONL room is the log; history is not a second copy of it.

## Decision

- The worktree/device JSONL room is the source of truth. History holds a
  **working set**: a short roster when the live set changes, and only the
  newest few inbound lines (byte-capped). `-p` still hears nothing that
  predates the process.
- Peer injects are not a human user turn. `cleanUserTurn`,
  `recentContextStart`, `emergencyCutIndex`, and `dropPriorTurnReasoning`
  ignore them as conversation boundaries.
- Forget at compact, never mid-turn. The summarizer does not see peer
  injects. The kept suffix drops *spent* injects (a later turn already
  followed them) and keeps a trailing *unreplied* inject. `durableState`
  restates who is live now, not quoted speech.
- Do not reopen device-wide model `"all"`. Do not invent a lock-claim parser
  here; the collision gate remains the safety net for a forgotten "I'm
  editing foo".

## Consequences

- Two sessions can talk without the room becoming another uncapped tool
  output. `/peek` and a later `peer_peek` re-read the log from disk.
- A compact that runs on a pending inbound does not swallow it.
- Revisit when structured claims exist (issue #563, later lock-claim slice):
  a live path+intent may then survive compact as harness state, the same way
  the goal checklist does.
