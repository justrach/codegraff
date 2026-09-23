# 0167. Workflow isolation belongs to dependent chains

Status: accepted 2026-09-23

## Decision

Top-level phase isolation creates one worktree for the entire workflow.
Pipeline isolation creates one worktree per item, shared by every stage and
retry of that item. First-stage isolation uses the same per-item scope.
Later stages cannot create a new isolated tree and lose earlier edits.

Children using shared cwd inherit the chain's working directory, including
when an experimental worker pool exists. Creating an independent child tree
uses the caller's repository rather than the process-wide directory.

At completion, remove only unchanged, verified-empty trees. Preserve dirty
or independently committed trees and deliver their paths and branches in
the tool result. This is an explicit handoff, not an automatic merge.

## Validation

The offline workflow integration drives real parent and child turns against
a scripted model. Later stages read prior committed edits, parallel items
retain different contents, caller files stay unchanged, and results identify
every retained tree and branch. The phase case verifies the same contract.
