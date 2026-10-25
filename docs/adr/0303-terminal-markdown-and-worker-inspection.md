# 0303. Inspect workers without replacing the line REPL

## Context

The terminal already renders Markdown blocks and streams inline bold and code,
but single-marker emphasis remained literal. Worker launch and completion rows
provided no in-terminal route to the activity and reports available to ACP
clients. A permanent multi-column layout would replace the line REPL's
scrollback and editor contract rather than improving it.

## Decision

Share inline emphasis handling between the streaming and buffered terminal
renderers. Render balanced asterisk and underscore emphasis, retain markers
inside URLs and identifiers, and support escaped punctuation. Keep styling in
the existing palette; plain output never gains terminal escape sequences.
Structured engine events and stored model text remain unchanged.

Expose `/workers [child-id]` as a read-only inspector of the current process's
existing bounded child-activity snapshots. `/agents` continues to list agent
types. In a colored terminal the inspector temporarily owns the alternate
screen: click or Enter opens a card, arrow keys scroll, Escape returns, and q
closes it. Refresh existing snapshots; never spawn, resume, steer, or cancel an
agent to inspect it. Outside the terminal, provide a plain list or report.

Use the same parent PID/start-identity directory and child IDs as the ACP
activity feed. Bound reads and event counts, reject invalid or mismatched IDs,
and strip untrusted terminal control sequences before rendering. Tool-result
bodies and already-emitted thought text expand only on explicit request;
failures remain visible. Indicate truncated snapshots.

## Consequences

The line editor, ordinary transcript, engine, ACP event shapes, and separately
maintained fullscreen client remain unchanged. Mouse reporting and raw input
are scoped to the inspector and restored on exit, including error paths.
Worker cards wait at the existing line-boundary gate while the inspector owns
the screen. Terminal scrollback itself is not a clickable native widget: the
launch row names `/workers`, where click and keyboard inspection are available.
Snapshots show bounded recent activity, not an unlimited historical transcript.
