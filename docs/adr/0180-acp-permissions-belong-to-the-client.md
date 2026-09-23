# 0180: ACP permissions belong to the client

Status: accepted

## Context

The engine already knows which operations require approval, but ACP previously had no frontend input bridge. Non-auto-approved desktop and editor sessions could only receive an unattended denial.

## Decision

This supersedes the permission-input limitation in ADR0032. Bind the existing engine permission handler to a standard server-initiated `session/request_permission` RPC during live ACP turns. Advertise explicit once, reject and, where the engine has a persistent approval key, always options. Always uses the existing scoped approval key and persistence mechanism; it does not widen plan mode or introduce blanket approval. Plan read requests offer once/reject only.

Match each response to one pending server request, accept only an offered option, and resolve cancellation, transport EOF or invalid responses as denial. Cancel and prompt completion retire pending input before another turn can request it. Explicit auto-approval continues to bypass requests.

The desktop owns the controls and delivery acknowledgement. It maps server IDs to unpredictable tokens scoped to the exact live transport, validates chat/session and offered options, and consumes a token once. A response from a replaced worker cannot approve the next worker even if its server IDs and restored session name repeat. Both prompt and idle-peer streams carry permission requests. Failed delivery stays visible.

## Consequences

The existing workspace auto-approval preference and default are preserved; this adds an interactive path when auto-approval is disabled. Persistent approvals retain existing scope (for example, an executable key), which is named in the Always option. No client decision bypasses unconditional engine policy checks. The bridge provides root permission input; detached worker approval policy is unchanged.

Offline coverage includes real ACP once/always/reject/cancel behavior and explicit auto-approval, transport stale/duplicate/wrong-session/unknown-option rejection, and a headless browser click through the production desktop route to actual tool execution.
