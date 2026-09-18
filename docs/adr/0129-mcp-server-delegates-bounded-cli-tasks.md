# 0129: MCP server delegates bounded CLI tasks

## Context

MCP clients need to delegate small tasks to the harness. The existing MCP
CLI configures outbound servers; the existing one-shot command already owns
model selection, credentials, project instructions, tool policy, and cleanup.

## Decision

Expose `graff mcp serve` over stdio with one `run_task` tool. Each call spawns
the current executable as a fresh bounded one-shot. The server launch fixes
the workspace, optional model, and permission mode. Default children use
`--safe`; only a server launched with `--yolo` grants unattended execution.
Tool arguments cannot raise permissions or replace configuration.

Reuse the process runner for output caps, deadlines, and process-tree cleanup.
Preserve partial output and error status. Guard nested server launches with an
inherited recursion marker. Initialization and discovery require no model
credentials. Keep the outer protocol independent of child stdout/stderr.

## Consequences

There is one harness implementation and a narrow MCP adapter. Initial calls
are serial and bounded; there is no progress, live cancellation, or resumable
conversation. Client disconnects are observed after the current bounded call.
A successful child exit does not independently verify its answer, and failed
work may leave edits behind. Future asynchronous support needs explicit task
ownership and cancellation rather than extending this synchronous contract
implicitly.
