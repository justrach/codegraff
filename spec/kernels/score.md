# Kernel: score maintenance

Source of truth: `lean-proofs/Graff/Score.lean`.

A fitness row is *maintained* (filed, comparable) iff:

1. the fleet is on
2. `roleOf(label, niche)` is a canonical slot (label first, niche fallback)
3. the stage carries a signal (`stageScore` is not null)

Unreached, all-fail, and `ok > attempted` file nothing — a 0 would poison
the cell mean. Off-vocabulary titles still run; they do not accrue.

Outbound scores are the `[0,1]` contract: values in `[0,1]` pass, `(1,100]`
are percentages, anything else is rejected. HMAC and the providerClass
price fallback are out of this kernel.

The MAP-Elites cell is niche + tier + slot. Changing any axis is a
different cell (v2). Uncelled rows are not comparable.
