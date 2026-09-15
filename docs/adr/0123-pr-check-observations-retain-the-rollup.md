# 0123. PR check observations retain the rollup

Status: accepted 2026-09-15

## Context

Current-head verification rejected failed checks, but retained only an aggregate
state. It discarded the check identities and gave the same explanation for
pending, failed, missing and stale evidence (#853). A local schema check could
therefore be mistaken for evidence about a different CI job.

## Decision

Keep the complete bounded remote check rollup with its head in a private local
receipt for each conversation's publication target. Retire the previous receipt
before observing again, including when the lookup fails or exits nonzero after
printing apparently valid output. Failure to retain evidence defers completion.
The receipt is diagnostic, never cached acceptance authority: each completion
attempt still fetches fresh remote evidence and compares the local head where
required. Check names and outcomes appear in deferred completion results, with
bounded display and the full rollup retained locally. Distinguish pending,
failed, missing, unknown, draft and stale-head reasons.

## Verification

`scripts/test-pr-check-receipts.py` drives production publication and completion
through an offline model and GitHub fixture. It covers named mixed check results,
repeated completion with completed todos, pending/missing/unknown observations,
a different remote head, unavailable lookups, failed exit with green output,
and passing evidence. It checks actual tool events against the retained receipt.
