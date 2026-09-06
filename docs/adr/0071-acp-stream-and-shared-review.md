# 0071 — ACP response routing and shared review

Status: Accepted

## Context

Catalog queries and prompt streams share a graff process. Competing stdout
readers can consume each other's replies and lose assistant notifications.
Workspace review also needs to show edits from every actor, rather than only
the files mentioned in one conversation.

## Decision

Use one ACP stdout reader with request-ID routing and explicit notification
subscriptions. Reject overlapping prompt streams, settle pending requests on
process exit, and stop writing to cancelled HTTP streams.

Expose read-only `graff/changes` status and diff requests. The GUI reviews Git
working trees, refreshes only while visible, and offers staged/unstaged scopes,
worktree selection and recent commits. Uncommitted authorship is not inferred.

## Consequences

Catalog refreshes cannot steal response bytes. Git supplies shared file state,
but separate worktrees must be selected individually and remote pull-request
synchronization remains a separate feature. Diff output and subprocess time
are bounded; external diff drivers and text conversion are disabled.
