# 0121. Artifact claims include repository identity

Status: accepted 2026-09-15

## Context

A live publication claim could block edits to a separately owned PR in another
repository. The ledger stored only artifact kind and key, so matching names or
numbers collided across repositories. Publication claims also could not be
compared with a numbered PR's branch (#925).

## Decision

Claims persist a canonical host/owner/repository identity. Claim, release,
handoff and status accept an optional `repo`, defaulting to the workspace
repository resolved by GitHub CLI. The same artifact key may exist in distinct
known repositories. Unknown scope remains conservative; ambiguous operations
must specify a repository rather than choose the first matching record.

Before a literal PR mutation, observe its repository URL, number and head
branch through GitHub CLI. Compare publication/branch claims with that branch
and PR claims with its number. A fork head repository also participates in
branch/publication ownership; unknown head identity stays conservative. PR URLs and
options before the selector retain the same identity. Unknown shell forms and
unavailable evidence cannot release a live claim. Git mutations retain their
existing conservative checks; this is not a universal shell sandbox.

Legacy records have unknown repository scope. Their live owner can re-claim
the artifact with a resolved repository to bind it without a release window.
Other sessions cannot rebind a live owner's claim. Scope is retained through
handoff and serialization; repository lookup failure is never proof of freedom.

## Verification and costs

Two live harness processes exercise edit and ready across repositories,
branches and hosts, PR URLs, flag order, unavailable evidence and legacy
migration. The old release blocks the independent-repository case. A JSON
behavior case proves releasing one repository's PR claim preserves another
with the same number. Pure tests cover persistence and ownership transitions.

Claim operations may perform a bounded read-only repository lookup. PR target
lookups occur only when foreign claims exist. Remote lookups run outside the
ledger lock; mutation gating reloads the ledger afterward so a peer can release
its claim during a slow lookup and the decision sees that release. No ownership database outside
the existing workspace ledger is introduced.
