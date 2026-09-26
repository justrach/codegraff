# 0206. ACP v2 preview behind a gate

Status: accepted 2026-09-26.

## Context

ACP v2 is a draft. It changes the prompt contract: `session/prompt` is
answered once the user message is inserted, with that message's `messageId`,
and the turn's outcome arrives later as a `state_update` (`running`, then
`idle` with a `stopReason`). It also requires a `messageId` on every message
chunk, removes `tool_call` (the first `tool_call_update` creates the row),
renames `initialize`'s `agentInfo`/`agentCapabilities` to `info`/`capabilities`
with object markers, and reserves non-underscore variants for the spec.

Every client graff ships to today speaks v1. A v1 client that is sent v2 shapes
would silently lose turn completion.

## Decision

- v2 is used only when the client asks for `protocolVersion` >= 2 **and**
  graff was started with `GRAFF_ACP_V2=1`. Otherwise `initialize` answers 1
  and every byte stays as it was.
- The negotiated wire is a process global (one ACP connection per process),
  latched at `initialize`. The v1 writers branch on it rather than a second
  set of writers, so a feature cannot reach one version and miss the other.
- A v2 prompt is acknowledged before the turn runs. Errors that happen before
  insertion are still JSON-RPC errors; a turn that fails later idles with the
  custom stop reason `_error` and the message in `_meta["graff/error"]`.
- Message IDs are minted per process (`msg_<role>_<seed>_<n>`). A new ID
  starts when output switches between thought and text, or after a tool event.
- The draft child-session stream (ADR 0194) is a v1-era proposal and is off in
  v2; subagents report through tool-call content (ADR 0205).

## Consequences

Harness and other clients can build against the v2 lifecycle now without
graff changing behavior for anyone else. Replayed history gets fresh message
IDs, which v2 forbids for retained prompts; persisting IDs in the saved
session is the next step. `session/list`, `auth/login`/`auth/logout`,
`plan_update`, structured diffs, terminal updates and JSON-RPC batches are
not implemented yet.
