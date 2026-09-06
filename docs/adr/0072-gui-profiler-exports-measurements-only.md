# 0072. GUI profiling exports measurements only

Status: accepted for the local desktop trial

## Decision

Desktop profiling is off by default, bounded to ten minutes, and callable
through the local MCP adapter or native Performance menu. It records interval
process-tree CPU and RSS, main-loop delay, renderer long-task durations, and
allowlisted navigation/action/failure events. Baseline and candidate phases
are fixed labels; retained samples and events are bounded.

Feedback exports use an explicit measurement schema. No raw event objects,
prompts, model/account/session identifiers, paths, URLs, titles, screenshots,
exception text or free-form annotations are serialized. A native save dialog
writes a reviewable local JSON artifact. There is no automatic upload endpoint.

## Consequences

A report supports performance comparisons without reproducing user content.
It cannot diagnose failures that require a content-specific reproduction.
CPU samples may miss short-lived children, and RSS can double-count shared
pages. Tests enforce the allowlist and bounded retention with sensitive input
fixtures. Sending a report remains a separate user-directed action.
