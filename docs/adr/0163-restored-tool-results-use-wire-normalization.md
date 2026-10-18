# 0163. Restored tool results use wire normalization

Status: accepted 2026-09-23

## Decision

Session restoration and request admission share one tool-payload repair pass.
Legacy byte arrays decode to text, scalar results retain their serialized value,
and valid typed content blocks remain structured. Repair applies to each
supported legacy tool-result wire shape before requests are serialized.

Client tool calls on the Messages wire also require receipts immediately after
an assistant batch. On restore and request admission, move any delayed actual
receipts ahead of intervening notices without changing their typed content.
For a missing receipt, record an error stating that the execution outcome is
unknown; never replay a tool or claim it did not run. The batch error path closes
these pairs before history can be saved. Server-side tool blocks are untouched.
This belongs in the shared engine, not REPL or ACP notification rendering.

## Evidence

The saved-session regression writes malformed results through the production
save path, restores them into an empty history, and inspects the serialized
request for all three wire formats. A separate check preserves image blocks.
History navigation tests cover draft restoration and oldest-entry clamping.
Pairing regressions inject a batch-execution allocation failure, move delayed
typed receipts, and serialize a restored session with a missing receipt.
