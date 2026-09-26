# 0133. Publication review binds committed inputs

Status: proposed

## Context

Passing a helper test does not establish the behavior of its caller. A PR
description can claim dispatch coverage that neither its committed tests nor
the implementation support. Keyword checks cannot establish that coverage.

## Decision

Non-draft publication receives a bounded, tool-free review of the PR body,
exact repository/base/head, changed committed source and tests, and separately
identified check observations. Missing required evidence, oversized diffs,
unsupported inputs, and unresolved or malformed review results do not establish
readiness. Drafts remain available. No particular wording is required to
trigger review.

Changed files supply the proposed-head blob when it fits and a context diff
for prior lines; unchanged base blobs are not repeated. When a complete
proposed-head blob exceeds the individual or aggregate source budget, its
committed context diff remains available with an explicit omission marker.
The reviewer must return unresolved if the missing source is needed to assess
a claim. An oversized diff still blocks publication. Test entry points follow
committed package scripts and runner imports through a bounded chain. The
packet names size and traversal limits when evidence is omitted. Successful
local check receipts remain bounded and survive session restore, with their
observed head and completion status; they are not immutable execution proof.

The review supplements actual tests and fresh CI observations. It is not a
mechanical coverage certificate. Changed files may omit important callers;
the reviewer must retain uncertainty rather than invent those paths. A check
receipt records what the harness observed, including incomplete output and
post-run identity limits, without claiming immutable execution.

Review requests share the caller's model budget and cancellation. Successful
assessments may be reused in the same process only for matching repository,
base, head, body, source and check observations. The common execution boundary
revalidates those inputs. A new process or changed input requires new review.

## Consequences

Non-draft publication can require an additional model request. Large changes
or missing dependencies can remain unresolved even when local checks pass.
The review must not hide those limits or substitute a passing assessment for
execution evidence. Runtime regressions must cover both refusal and acceptance,
input changes, alternate targets, cancellation and exhausted budgets before
this proposal is considered fully verified.

Related: #847; extends ADR 0100 and ADR 0126.
