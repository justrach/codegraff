# DRAFT. ACP answers `initialize` during boot

Status: proposed. The integrator assigns the number and adds the index row.

## Context

An ACP client spawns `graff acp` and sends `initialize` first. The dispatch
loop started only after the root Agent existed, so the answer waited for the
whole boot: worktree identity, MCP registry, settings, companion, approvals,
system prompt and root construction. The response itself reads none of that.
It depends on the request, the `GRAFF_ACP_V2` gate (ADR 0206), the version
string and whether the dispatch can load sessions. The credential-free path
already answers it without an Agent.

Answering earlier has three ways to go wrong. The request could be answered
twice, or not at all. A stdin byte could be lost or reordered between an
early reader and the loop's reader. Or the live `Dispatch` and the process
latches that `initialize` sets could differ from the late path's.

## Decision

- Each boot phase mark is also a check, and so is the point where stdin and
  stdout are created. The check runs on the main thread. It reads stdin only
  while `poll` reports it readable, so boot never waits for the client. It
  never reads past a full buffer, and it never reads outside ACP.
- There is one stdin reader. The ACP inbox pump later reads the same reader,
  so the bytes after the first line stay where they were.
- A complete first line that is an `initialize` request with an id is taken
  off the reader. The engine's own `handleLine` answers it on a fresh
  dispatch whose `can_load` matches the live one. The answer is written only
  to a clean protocol stdout. The line is kept.
- Any other first line (no `initialize`, a notification, invalid JSON, or a
  line larger than the buffer) is left in place. So is an incomplete one.
  After a non-`initialize` first line the checks stop.
- When the loop starts, the kept line is dispatched through the normal loop
  body first, and its output is discarded. The live dispatch fields and the
  latches are rebuilt by the code the late path runs. The latches are
  last-writer-wins: the v2 message-id seed is the live dispatch's.
- One pure `step` makes the decision. It is modelled in
  `lean-proofs/Graff/AcpEarlyInit.lean`, and the Zig code calls it. The
  model proves, for every boot trace:
  - the first `initialize` is answered exactly once;
  - the replay writes nothing;
  - a non-`initialize` first line reaches the loop unchanged;
  - stdout and the dispatch history equal the late path's.
  A 360-cell cube shows that the early answer plus the replay leaves the same
  bytes and latches as the late path. The conformance test runs the real
  engine on every cell.
- No thread is added, so no TLA+ model is needed (`formal/README.md`).

## Consequences

`initialize` arrives within one boot phase of the request instead of after
root construction. `session/new` and everything after it still wait for the
loop. The no-credential pre-auth path is unchanged.

Differences from the late path:

- If boot fails after the early answer, the client has seen `initialize`
  succeed and then sees EOF. Before this change it saw EOF alone.
- The handshake log's `startup` phase still measures time to the loop. It
  times the replay, not when the client was answered.
- A request that arrives during root construction, the longest phase, is
  answered at the `root agent` mark, only slightly before the loop would
  have answered it. Boot code inside a long phase can call
  `acp_early.check()` between its steps to narrow the gap.
- Windows has no `poll` on stdin. There, only bytes already buffered count,
  which in practice means the late path.
