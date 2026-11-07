# 0299. Conversation-history forks are explicit, independent worker snapshots

## Context

ADR 0232 deliberately gives normal children a small request prefix instead of
copying the parent's entire conversation. That remains a useful default, but
it cannot continue an investigation whose evidence is in prior assistant turns
and tool results. ADR 0170 already owns durable worker histories; session forks
already own independent root conversations. Neither needs to become a shared,
mutable agent history.

## Decision

`subagent.fork_from` opts into a conversation snapshot:

- `current`: the caller's completed history, before its in-flight spawn batch.
- `session:<name>`: a saved conversation in the current project; no arbitrary
  path, home-directory search, credential lookup, or source-agent execution.
- `worker:<task_id>`: a completed retained worker owned by the same parent
  family. Existing locking, forgotten-worker, deadline and budget checks apply.

The child gets its own deep copy and then the new task. The source checkpoint
is not rewritten, and siblings cannot append to one another's histories.
Queued mail belongs to the original worker and is not consumed by a fork.
`subagent_resume` still continues the original; a fork creates another child.

The child keeps its own instructions, tool catalog, approvals and selected
workspace/isolation. Source goals, live handles, credentials, root instructions
and loaded-tool announcements are not adopted. A retained source's read-only,
text-only and deadline restrictions cannot be relaxed by forking it. This is a
conversation fork, not a copy of uncommitted filesystem changes.

Same-wire history keeps native completed tool receipts and images. Across wire
formats, visible dialogue and tool receipts become inert historical text rather
than executable calls. Opaque compaction requires the original provider, model
and wire; images require the original wire. Refuse unsupported transfers rather
than silently dropping evidence. A native opaque window keeps its provenance.

`retained: true` remains a separate opt-in: it saves the new child's history and
workspace and returns its own `task_id`. Omitted retention remains ephemeral.
`workflow` accepts the same top-level `fork_from` and `retained` fields for
phases and pipelines. It resolves its source once, copies it independently into
each worker, and preserves retained chain workspaces even when they are clean.
Judges do not inherit the source or gain persistent workers. All paths use the
shared engine on the REPL and ACP, not client-only behavior.

## Consequences

Existing lightweight delegation is unchanged. Explicit full-history fan-out
costs memory and input tokens per child; it does not promise the parent's
cached system/tool prefix. Ephemeral workers that already finished have no
history to recover: retain them when future continuation is wanted.

Validation lives in `subagent_history*_tests`/`subagent_history_copy.zig` and
`scripts/test-subagent-fork.py`: owned snapshots, native/cross-wire evidence,
opaque and image refusal, ownership/budget restrictions, independent siblings,
original-only resume, and retained phase/pipeline fan-out through ACP and the
legacy JSON surface.
