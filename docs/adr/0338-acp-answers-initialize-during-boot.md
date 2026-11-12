# 0338. ACP answers `initialize` during boot

Status: accepted 2026-11-12

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
- For a complete first line that is an `initialize` request with an id, the
  engine's own `handleLine` renders the answer on a fresh dispatch whose
  `can_load` matches the live one. The answer is written only to a clean
  protocol stdout. Only after the whole line was written and flushed is the
  request taken off the reader and kept. If rendering or the write fails,
  nothing stays buffered, the line stays on the reader and the checks stop.
  The loop then answers it, or fails the way it would have anyway.
  (Bytes the OS accepted before a write error cannot be taken back. The
  transport is broken by then, and the loop's write fails too.)
- Any other first line (no `initialize`, a notification, invalid JSON, or a
  line larger than the buffer) is left in place. So is an incomplete one.
  After a non-`initialize` first line the checks stop.
- When the loop starts, the kept line is dispatched through the normal loop
  body first, and its output is discarded. The live dispatch fields and the
  latches are rebuilt by the code the late path runs. The latches are
  last-writer-wins: the v2 message-id seed is the live dispatch's.
- One pure `step` makes the decision. It is modelled in
  `lean-proofs/Graff/AcpEarlyInit.lean`, and the Zig code calls it. Over
  every boot trace, including ones where the early answer fails, the model
  proves line bookkeeping only:
  - the first `initialize` is answered exactly once;
  - a line is taken only after its answer was sent;
  - the replay writes nothing;
  - a non-`initialize` first line reaches the loop unchanged;
  - stdout and the dispatch history equal the late path's.
  It assumes that the response is a function of the request alone, and that
  equal dispatch history means equal dispatch state. It says nothing about
  bytes, the poll, the reader or timing.
- The byte-equality claim rests on two tests, not on the Lean kernel:
  - the Zig conformance test, which runs the real engine early and late on
    each of the 360 cells of the `initialize` cube and compares bytes and
    latches;
  - `scripts/test-acp-early-init.py`, which drives the built binary at
    random write offsets during boot and compares stdout with a client that
    writes after boot.
- A build without ACP (`-Dacp=false`, `-Dminimal`) declines at comptime, so
  the engine is not compiled in.
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
- A request that arrives during root construction is answered at the
  `root agent` mark, just before the loop would have answered it. With
  worktree identity resolved in-process that phase takes about 2 ms, so
  `buildRootAgent` has no checks of its own. If it grows long again, it
  needs a check between its steps; none exists today.
- Windows has no `poll` on stdin. There, only bytes already buffered count,
  which in practice means the late path.
