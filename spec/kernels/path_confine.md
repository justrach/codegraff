# Kernel: path confine

Source of truth: `lean-proofs/Graff/PathConfine.lean`.

File tools: no empty path, no absolute path, no `..` component. A confined
path still fails if any `/`-prefix is a symlink. `--yolo` does not lift
this. The worktree lease is `ownerVerdict`: only a live foreign (or
unverified) process in *this* worktree warns.
