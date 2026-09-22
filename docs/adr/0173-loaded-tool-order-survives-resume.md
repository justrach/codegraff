# 0173. Loaded tool order survives resume

Status: accepted 2026-09-23

## Context

A native tool loaded after an external tool was inserted before the existing
external schema. This changed the reusable catalog prefix. Saving the two kinds
separately also lost their interleaved order when restoring a session.

## Decision

Both kinds use one admission sequence. Render the loaded tail in that order and
persist an ordered list of names alongside the legacy selection fields. Restore
names against the current catalog; do not persist schemas or permissions. Older
snapshots retain their original native-first restoration behavior.

## Consequences

Appending a loaded tool preserves the bytes of prior catalog entries. Real
save/load and emitted-request tests guard this property. Actual cache hits remain
provider-dependent; stable catalog bytes alone do not establish a billing gain.
