# 0100. Publication claims and verified completion

Status: accepted 2026-09-10

## Context

Three failures shared one gap: the harness treated awareness, a successful
`gh pr create`, and a rewritten checklist as proof of readiness.

- #847: non-draft publication sanitized outbound text but did not inspect the
  exact head SHA, require a Verification section, or reject an absolute claim
  backed only by a helper/one-separator test. `gh pr checks --watch` after
  create is too late.
- #840: `presence.gateCheck` ACKs a live peer once. An acknowledged handoff
  in prose did not block a later `gh pr create` by the other session.
- #844: `clearEpochForReplace` dropped omitted open verification items;
  `completionGate` then accepted, and `mainloop_trace.record` set
  `Outcome.success` from a normal agent return.

## Decision

Bash GitHub writes go through `publish_gate` before execution: a live foreign
artifact claim blocks, and a non-draft `gh pr create` / `gh pr ready` is
refused unless head evidence, verification text, and claim-vs-test review
pass. Drafts and PR-only workflows (no pre-PR run) remain allowed.

Claims are structured (`peer_message` action=claim|release|handoff|status).
ACK, polling, and a missing PR do not transfer ownership. A gone owner is
stale and may be acquired. The ledger persists in `.graff/artifact-claims.json`.
Every claim operation and publication check reads fresh state under a stable
sibling file lock. Mutations replace the ledger while holding that lock; lock,
parse, and persistence failures are errors, never evidence that work is free.
Handoffs resolve the receiver through live peer addressing and store its
canonical session, PID, and process-start identity. Unknown liveness remains
held. Explicit targets narrow a check only within comparable key namespaces;
compound or unrecognized commands retain conservative checks.

Verification checklist items survive a replace. `completionGate` will not
accept while they are open, including on the armed second call. Recipe
`success` is verified task success (`executed && taskVerified`), not a
normal return.

## Consequences

A session that has not recorded head CI still publishes when status is
`none` (PR-triggered workflows) if the body has a Verification section.
Live `gh run list` is not required in unit tests; evidence is injected or
parsed from a run-list JSON fixture. Custom personas still receive the
publication-ready note (ADR 0066).
