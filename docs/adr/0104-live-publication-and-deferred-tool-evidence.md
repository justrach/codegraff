# 0104. Refresh evidence at the action boundary

Status: accepted 2026-09-11

## Context

The first version of ADR 0035 still joined every pending MCP handshake on the
second request. ADR 0100's publication evidence could be cached across commits,
and an unavailable lookup was indistinguishable from a valid empty run list.
Artifact claims were read once and rewritten without an interprocess lock.

## Decision

Only completed MCP tasks join at request boundaries. A task publishes a stable
atomic completion flag after handshake cleanup; only then does the request
thread consume its future. Explicit inspection and teardown retain blocking
joins. This updates ADR 0035 without changing first-request catalog policy.

PR publication inspects fresh evidence, with unknown distinct from no runs.
The literal command parser separates flags from quoted body content and reads
body files. Explicit remote heads do not inherit local HEAD evidence. A
publication arms a durable obligation keyed to the existing saved conversation
UUID, so renaming, compaction, and resume cannot satisfy it. Completion reads
current remote head/check data and compares the local head where applicable.
Draft handoff is labelled unverified. It cannot record verified task success.
This extends ADR 0100; a prose review remains heuristic, not proof of coverage.

Claims use a stable lock inode, bounded contention retry, fresh reads, and
atomic data replacement. Failed storage does not report a successful handoff.
The common bash executor repeats the check after earlier permission checks.
The coordination scope is the workspace ledger; this is not a universal shell
sandbox or a cross-workspace ownership database.

Clipboard extraction reads actual AppKit pasteboard types using the system
JavaScript runtime. Synthetic named boards exercise the production extraction
path without reading or modifying the user's general clipboard. The helper
creates no windows and does not activate another application.

## Consequences and verification

The offline release regression runs two independent harness processes to prove
handoff revocation and receiver access. An unfinished MCP handshake is released
only by the second native tool, proving the model request did not wait for it.
The same run streams citation arguments byte by byte. GitHub CLI fixtures check
failed/pending/unavailable evidence, fresh heads, draft handoff, repeated
completion, and resume. Native pasteboard regressions cover raster, PDF, file
URL, invalid, text, and empty inputs. No provider calls are required.
