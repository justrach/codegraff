# 0087. Bound retained desktop presentation work

Status: accepted

## Context

The syntax plugin retained highlighted tokens for every streamed code prefix,
including after its conversation closed. Repeatedly highlighting and reconciling
the growing fence also delayed rendering. Loading a saved conversation sent raw
message bodies to the renderer even though the transcript discarded most tool
output before display.

## Decision

Use one lazy syntax engine and a cache bounded by both entry count and estimated
storage. Cache keys include the complete source and theme identity. Bound pending
requests, preserve their delivery order and retain the complete text when a fence
exceeds the highlighting limit.

An incomplete live code fence renders plain code text. Apply syntax highlighting
when the fence closes or the turn ends. Keep the existing code controls. Animated
text updates belong to their text component, and each transcript follows only
its own content. Split dragging updates the adjacent pane styles on animation
frames and commits layout state when the drag ends.

Long completed chat fences initially highlight a line-limited preview. Explicit
expansion reveals the complete source, and Copy always uses the original source.
Document views remain fully expanded. This bounds token spans and layout work
without discarding code. Markdown and diagram views share a lazy theme observer;
the last subscriber disconnects it, and unrelated root-class changes do not
notify views.

Initial transcript rendering is bounded by both message count and content size.
Code-heavy histories can exhaust the renderer even below the message-count cap.
Keep the latest request/reply readable, page older messages on explicit request,
and preserve the reading anchor. A live tail advances this window until the user
starts reading or explicitly reveals older history; saved data is never removed.
Tail tracking distinguishes content growth from upward scrolling, and observes
transcript content size so delayed formatting does not strand the viewport.

The desktop requests the saved-session transcript projection explicitly. The
server uses the same transcript decoder as the previous client path; the default
session API continues to return raw messages. This avoids transferring discarded
tool output and retaining large backing strings in the renderer.

Keep Chromium's normal hardware acceleration, display synchronization and hidden
window throttling. Verify performance using the same synthetic workloads before
and after each change. Keep raw measurements and traces local. Frame callback
timing alone is insufficient evidence of display presentation.

## Consequences

Live code gains syntax colors when its block finishes. Long completed chat fences
need expansion to read beyond their preview. Expanded very large fences remain
fully readable and copyable without syntax colors. Cache weights are conservative
estimates rather than exact engine allocation sizes. Grammar data remains shared
for the renderer lifetime.

Changes to transcript projection must preserve displayed conversations and remain
compatible with the raw session response. Unit and native rendering regressions
cover cache eviction, async ordering, incomplete and completed fences, history
parity, reading position and split resizing.
