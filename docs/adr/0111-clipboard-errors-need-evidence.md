# 0111. Clipboard failures do not imply Automation permission

Status: accepted 2026-09-14

## Context

Clipboard helper launch failures, timeouts, invalid output, and repeated
pasteboard changes all produced advice to grant Automation access (#883).
The exporter already uses AppKit directly through the system JXA runtime;
it does not send Apple Events to another application. Named-pasteboard
regressions exercise the real exporter without modifying the general board.

## Decision

Keep direct AppKit extraction and its image-flavor fallback. Do not introduce
application scripting or ask users to change Automation permissions for a
generic helper failure. Classify bounded process results before decoding the
export protocol, and identify denial only from an explicit, complete system
error. Never display helper stderr or clipboard contents in diagnostics.

Expose launch failure, timeout, clipboard churn, export failure, and conversion
failure separately. Offer retry and the existing terminal text-paste or
`/image <path>` workflows rather than inventing a permission requirement.

## Consequences

`osascript` remains the system JXA host, not an Automation target. This avoids
adding a platform-specific linked helper or runtime compiler dependency.
Unknown failures remain neutral read errors; they do not establish which
macOS privacy setting, if any, applies. Tests use private named pasteboards and
injected process failures, so normal clipboard contents remain untouched.
