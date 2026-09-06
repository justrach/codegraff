# 0076. Local agent coordination stays in Graff

Status: accepted

## Decision

The GUI defaults to peers in the current worktree, with an explicit device-wide
view. The `graff/agents` ACP extension exposes verified live peers, bounded recent
room history, and explicit addressed human messages. Discovery compares process
start identities, not PID alone. Old peers without a verifiable identity are
excluded. Legacy activity is shown as connected, never inferred from CPU usage.

A lightweight observer entry point bypasses provider, MCP and session startup.
It serves the same extension independently of a busy model turn. It creates no
presence entry and does not read or advance a session's inbox cursor. Inspection
is bounded to recent complete log records. Message submission revalidates the
selected recipient's start identity; it never silently retargets a stale choice.

Delivery is queued to the recipient's next step boundary. A handoff is an explicit
coordination request, not a claim that task ownership transferred or a peer read
or accepted the message. No automatic messages are sent by opening the panel.

Per-peer resource sampling measures the Graff process only. Shared workers and
GPU usage cannot be reliably attributed. Feedback exports use anonymous slots
scoped to a single bounded recording and numeric resources only, never peer
names, tasks, paths, PIDs, process identities or message content. Recording and
export remain opt-in, with no automatic upload.
