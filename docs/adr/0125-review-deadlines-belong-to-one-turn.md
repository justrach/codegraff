# 0125. Review deadlines belong to one turn

Status: accepted 2026-09-15

## Context

Review mode supports call and tool limits, but a single stalled model request can
consume wall time without reaching another call-count check (#306). A timer that
outlives its review can incorrectly cancel an unrelated follow-up.

## Decision

`GRAFF_REVIEW_MAX_SECONDS` opts explicit root reviews into a wall-time limit.
Unset or zero remains unlimited; positive integer values up to 86400 are accepted.
Malformed values reject the review instead of silently disabling the limit.
Ordinary turns and subagents do not inherit a review deadline.

Each review owns a joined watcher. At the deadline it requests cancellation with
a distinct harness source, preserving any previously recorded user cancellation.
The watcher stops and joins before the turn returns. A result arriving after the
deadline cannot become successful completion. Reports say the review is incomplete
and do not blame the user. Follow-up turns receive their normal fresh cancel state.

This uses the existing cooperative cancellation paths, including network waits;
it is not process isolation for an uninterruptible operating-system call.
It adds no default cap and does not change review's read-only capabilities.

## Verification

Unit tests cover parsing, watcher teardown, cancellation provenance and late
results. `scripts/test-review-deadline.py` holds a model response open, observes the
review timeout, then completes ordinary/review/ordinary follow-ups in the same
process. The ordinary turns deliberately exceed the configured review limit.
The existing long-review and explicit call/tool-budget regressions remain intact.
