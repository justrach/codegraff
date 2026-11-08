# 0317. nanocua keeps text and opts in to geometry

Status: accepted 2026-11-08. Extends [0314](0314-nanocua-is-grafts-computer-use.md).

## Context

A short observation is not useful if it hides the answer or the label needed to
act. Headless task comparisons using the production serializer showed that
controls-only filtering can hide calculated results, validation errors and
child labels. Recovering them through additional reads can erase its savings.
Omitting frames preserves that text, while ref-based actions already resolve
current geometry when they need it.

The reproducible [utility comparison](../../apps/nanocua/evals/utility/README.md)
uses synthetic state, not native desktop automation. It supports this bounded
choice, not a claim of equivalent utility across arbitrary applications.

## Decision

`get_ui_tree` defaults to full text within its existing limits and no frames.
`include_frames: true` restores coordinates. Frameless macOS walks omit
AXPosition and AXSize from the batched attribute request rather than fetching
and discarding them. Child traversal, labels, values, enabled/focused/selected
state, ref generation and live action targeting do not change.

`interactive_only` stays opt-in, with descriptions warning against using it for
reading results or verification. Do not make it the default on the strength of
single-observation size alone. Permissions and Space restrictions are unchanged.

## Consequences

Callers that consumed coordinates by default must request `include_frames`.
Coordinate-based tasks can use that escape hatch; ref-based ones need not pay
for geometry they never read. Attribute count is lower, but no native AX latency
improvement is asserted without a controlled desktop measurement. Full-session
billing also depends on the harness and agent, not just the observation.
