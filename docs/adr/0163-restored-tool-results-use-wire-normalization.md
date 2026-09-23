# 0163. Restored tool results use wire normalization

Status: accepted 2026-09-23

## Decision

Session restoration and request admission share one tool-payload repair pass.
Legacy byte arrays decode to text, scalar results retain their serialized value,
and valid typed content blocks remain structured. Repair applies to each
supported legacy tool-result wire shape before requests are serialized.

## Evidence

The saved-session regression writes malformed results through the production
save path, restores them into an empty history, and inspects the serialized
request for all three wire formats. A separate check preserves image blocks.
History navigation tests cover draft restoration and oldest-entry clamping.
