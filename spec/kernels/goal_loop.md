# Kernel: goal / completion

Source of truth: `lean-proofs/Graff/GoalLoop.lean`.

Harness-done, not world-done. `completionGate` says whether
`attempt_completion` may be accepted. Empty checklist is never done.
A restored all-`[x]` list is not this-process evidence (`dirty`).
Standing `--goal` records a claim and does not retire.
