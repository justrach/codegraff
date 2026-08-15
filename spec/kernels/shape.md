# Kernel: optimal shapes

Source of truth: `lean-proofs/Graff/Shape.lean`.

Closed catalog: review / research / design / migration / feature / adhoc.
Unknown names are adhoc, never a guess.

`classOf` precedence is the whole function: audit-class language is REVIEW
even when it mentions bugs; a repair ask with no breadth word is BUGFIX even
when it mentions a review.

`ladderRung` is the smallest rung that fits, ordered by precedence not cost:

1. R0d — first verified failure on a 1–2 file non-audit ask
2. R3 — audit language or a prior failure, and the fleet still fits
3. R1 — research, and not an audit
4. R2 — 3+ files, width ≥ 2, fleet still fits
5. R0 — the floor

An explicit user shape is honoured at R2 or above and is never traded down.
`fleetAffordable` is computed in Zig from remaining/cap vs `fleetFloor`;
cap 0 is unlimited.
