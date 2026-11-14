# 0342. Assistant replay is not an intentional prefill

## Context

A fresh worker starts with a user task, but that does not guarantee every
request ends with a user turn. A Messages reply with `pause_turn` is saved as
an assistant turn and immediately continues without a tool result. Retrying
a failed turn can likewise retain an assistant tail. Serializing that history
verbatim asks the backend for assistant prefill, which some models reject
before any tools run (#1895).

The worker's pinned-seat fallback also treated this invalid-history rejection
as a reason to try another seat. That changes the model, not the malformed
conversation, and can produce a second deterministic rejection.

## Decision

At the shared Messages request-body boundary, preserve a trailing assistant
reply and append one harness-authored user continuation. Store the continuation
in the agent's history, not only in serialized output: subsequent retries and
signed-thinking replay must see the same prefix. A user task or tool-result
turn needs no extra note. Existing dangling-tool repair runs before this guard
and retains its explicit interrupted-tool outcome rather than replacing it
with prose.

Use the same boundary for native credentials, gateway traffic, workers and
roots, and both REPL and ACP. Other wire formats are unchanged. A residual
assistant-prefill rejection remains a structural failure and must not earn a
pinned-seat fallback or an unchanged worker retry.

## Consequences

A continuation costs a small user turn only when a request would otherwise
end with an assistant reply. Existing assistant text, signed reasoning and
tool evidence are preserved. Rebuilding the body is idempotent; a second
rebuild does not append another continuation or change the request bytes.

Offline regressions exercise a pause before the first tool, native and gateway
serialization, login-token serialization, root/worker callers, interrupted-tool
receipts and the no-fallback failure path. They do not call a live backend.
