# 0194. Native learning checks a pinned formal baseline

Status: accepted 2026-09-23

## Context

The local learning store already pins its adapters and evaluation suites, and
rechecks their immutable evidence before promotion. A separate, bounded formal
checker can establish properties of the shared engine's modeled control flow.
Its success is not evidence that a newly generated prompt is correct. The
existing signed aggregate receipt also has no field for a formal check.

## Decision

An optional `formal_check` configuration pins the checker executable, its
script, and its input manifest. The manifest's engine binary must be an exact
pinned input and argument to both learning adapters. Before mutation, and
again for a selected genome, the checker must succeed for the respective
prompt fingerprint. The store saves content-addressed check evidence in a
versioned pending record and run record. Resume and manual or automatic
promotion re-run the pinned checker and reject missing, stale, or mismatched
evidence. Default configurations do not enable this gate.

Formal-enabled trials stay local. `run --submit`, `learn submit`, and direct
submission reject them until a signed receipt version binds the formal
evidence. The legacy fleet persona promotion path remains separate and has no
formal gate.

## Consequences

The checker consumes local time at admission, selection, resume, and
promotion. Operators must supply its signing key file and trust the pinned
checker, adapters, and manifest; pinning proves their byte identity, not that
an adapter actually uses its binary argument. The model-check result concerns
the pinned shared engine baseline. Behavioral correctness of a candidate
prompt still depends on the normal paired evaluations and holdout gate.
