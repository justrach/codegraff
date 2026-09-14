# 0111. Live citation filtering belongs to terminal presentation

Status: accepted 2026-09-14

## Context

Completed-text sanitization did not protect incremental reasoning, answers, or completion arguments (#874). A citation delimiter or its payload can cross any chunk boundary. Filtering individual chunks loses that context; filtering engine events would also change structured clients' input.

## Decision

Apply the existing incremental citation recognizer at terminal display boundaries, before markdown rendering, reasoning replay buffers, or fullscreen live prose buffers. Keep reasoning state independent from answer state and reset it at stream start and completion, interruption, or transport failure. One-shot and hosted terminal output use the same recognition contract. Keep structured JSON and ACP serialization and raw tool output unchanged.

## Consequences

The filter holds only delimiter-prefix bytes and suppression state, not citation payloads. Unclosed annotations are suppressed until the stream boundary; a fresh stream cannot inherit them. Each terminal adapter must retain lifecycle coverage. Real sink-dispatch regressions cover split delimiters, independent channels, reset recovery, and unchanged structured output; completed-text tests alone are insufficient.
