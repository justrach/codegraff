# 0089. Canonical compaction windows survive recovery

Status: accepted 2026-09-08

## Context

Automatic Responses compaction permits dropping items before the latest
in-stream compaction item. Standalone `/responses/compact` instead returns a
canonical window: all its output items must be retained. Treating these two
origins alike allowed later automatic pruning to discard retained items (#804).
Local summarization also returned successful zero work when history began with
an opaque item, preventing meaningful recovery while reporting no failure.

## Decision

Persist a fingerprint of the latest standalone compaction item alongside
session history. Protect that canonical window until a distinct automatic
compaction item supersedes it. Saves without provenance conservatively protect
the existing window; new saves explicitly distinguish automatic state.

A local summary cannot replace opaque state, wherever it appears in history.
Near-limit recovery uses the eligible server compaction route instead. A failed
server attempt reports failure and preserves history; it does not fall through
to a local summary or emergency trim of opaque context. Non-OpenAI routes do
not acquire server compaction support through this recovery path.

Show `Compacting…` only around an actual compaction operation, not merely
because a normal request enables automatic compaction. Keep detailed successful
compaction diagnostics behind debug mode.

## Consequences

Canonical context survives pruning, save/resume, and REPL history handoffs.
Legacy saves may retain more input until the next automatic compaction. A
server outage can block further context reduction, but cannot silently discard
opaque state or claim a successful local fallback. Regressions in
`agent_server_compact_tests.zig` cover retained windows and loopback server
recovery, including malformed server output.
