# 0004. Peer speech is a working set, not the conversation

Status: accepted 2026-08-18 (amended 2026-08-18: pull, not push)

## Context

#469 used to inject co-resident speech into history as `role: user`
(`[peer message from …]`, plus a presence roster). Each `deliverInbound`
**appended** another blob that lived until generic compaction. Compaction
then treated those blobs as the human: `cleanUserTurn` is true, so
`recentContextStart` kept the peer firehose in the ~8k verbatim suffix
and summarized the real prompt away.

That is a measured failure. `-p` one-shots seek the room to its tail
because ~4k tokens of stale chatter on the first step made ephemeral
workers *answer old messages*. Interactive sessions still dumped roster
+ clipped bodies + a footer into every later request.

Claude Code's product split is list / send / per-agent inbox — pull, not
a chat firehose. Anthropic's global-workspace write-up is interpretability
inside one model, not a multi-agent product; the useful borrow is the
tiny bottleneck, not J-space.

## Decision

- The worktree/device JSONL room is the source of truth. History holds a
  **one-line `[peer]` wake** when new inbound is parked. Bodies wait in a
  process-local ring (`peer_inbox.zig`). The model pulls with
  `peer_message action=inbox` and `action=list`. No roster essay, no
  full text, no footer paragraph in history.
- Peer injects (wakes and leftover `[peer message]` / `[presence]` lines
  in old transcripts) are not a human user turn. `cleanUserTurn`,
  `recentContextStart`, `emergencyCutIndex`, and `dropPriorTurnReasoning`
  ignore them as conversation boundaries.
- Forget at compact, never mid-turn. The summarizer does not see peer
  injects. The kept suffix drops *spent* injects and keeps a trailing
  *unreplied* wake. `durableState` restates a **count**, not names and
  goals.
- Do not reopen device-wide model `"all"`. Do not spawn a standing
  liaison. The collision gate remains the mutate-time wake.

## Consequences

- Two sessions can talk without the room becoming another uncapped tool
  output. The human still sees the full `session_notice` lines.
- A compact that runs on a pending wake does not swallow it.
- Revisit when structured claims exist (issue #563, later lock-claim
  slice): a live path+intent may then survive compact as harness state.
