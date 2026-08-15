# Kernel: hand ladder + explicit arm

Source of truth: `lean-proofs/Graff/Shape.lean`.

This is `escalation.ladderRung` and the explicit branch of `decide`.
It is **not** `admit`: learned override, ε-explore, and `observe` (file
tokenizer, session decline counts) are out of the cube.

Closed catalog: review / research / design / migration / feature / adhoc.
Unknown names are adhoc, never a guess.

Affordability is the live ledger: `fits(remaining, fleetFloor(shape))`.
cap 0 is unlimited. The cube includes a split budget (remaining=29, cap=100)
that admits adhoc and refuses design.

`ladderRung` precedence:

1. R0d — first verified failure on a 1–2 file non-audit ask
2. R3 — audit language or a prior failure, and the fleet still fits
3. R1 — research, and not an audit
4. R2 — 3+ files, width ≥ 2, fleet still fits
5. R0 — the floor

An explicit user shape is honoured at R2 or above and is never traded down.

The live string classifier is `src/shape_needles.zig`. Lean proves the
reduced-cue *order* only; the fixture cases are built from that needle table.
