# 0290. MCP task replies outlive child deadlines

Status: accepted 2026-10-17

## Context

The HTTP MCP client ended every request after 15 seconds. The task server
allows a child to run for up to 300 seconds, with a separate bounded
preprocessing step for long context. The client could therefore discard the
server's timeout result and captured partial output before the child reached
its own deadline (#1517).

## Decision

For `tools/call` of `run_task` with arguments accepted by the task server's
validator, derive the HTTP deadline from the child timeout, add the context
summarization budget only when required, and reserve 15 seconds for process
cleanup and delivery of the final result. Keep this allowance request-local.
Discovery, other tools and malformed task arguments retain the ordinary
HTTP deadline. User cancellation still interrupts the request immediately.

Reuse the server's argument validation and preprocessing limits rather than
maintaining a second timeout contract in the transport. Do not silently
replay a timed-out task: it may already have edited files.

## Consequences

A bounded task can return its explicit failure and partial output instead of
losing the transport first. Unresponsive task endpoints can occupy a request
for the bounded task allowance; unrelated requests do not inherit it.
Other MCP hosts still own their deadlines, and must allow the documented
child, preprocessing and reply budgets. This change does not introduce a
continuation handle or guarantee recovery after an external host disconnects.
