# 0186. Tool previews use original source ranges

Status: accepted 2026-09-23

## Context

Oversized tool results retain a head-and-tail preview and a saved full result.
A rendered preview includes an omission marker, so its length is not an offset
into the original result. Using that length to select additional diagnostic
lines can omit useful evidence or repeat a line already visible in the tail.
Collecting all diagnostic lines before checking their combined size can also
let one oversized line suppress later useful lines.

## Decision

Carry the original omitted range with the preview. Select whole diagnostic
lines intersecting that range; exclude lines whose contents are already fully
visible in the head or tail. Include a boundary-crossing line in full when it
fits, preserving its meaning and UTF-8 text. A plain-prefix fallback supplies
its own original range.

Select diagnostic lines within the remaining byte and line budgets before
allocating their rendered body. Skip a line that does not fit and continue to
later lines. Report the number of selected lines, without truncating individual
lines to force them into the preview.

## Consequences

This preserves the full-result handle, output limits, and tool status under
[ADR 0012](0012-overflow-handles-named-limits-extra-roots.md). A preview remains
partial, and the saved result remains available for paging. Tests cover omitted
and already-visible diagnostics, boundary crossings, oversized lines, and UTF-8.
