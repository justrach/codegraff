# 0291: Release builds use declared-task caching

## Context

The release and beta workflows build six CLI targets on Linux runners. A plain
`nanocompile zig build` transparently delegates to Zig; it does not cache the
nested compiler commands. Calling that a cached matrix would be misleading.
Nanocompile already supports explicit, ordered whole-task contracts, including
artifacts for targets its direct compiler cache conservatively bypasses.

## Decision

Pin the published nanocompile source revision and build it with the same pinned
Zig as the CLI. Run each matrix build as one declared task. Include tracked
repository files, the fetched dependency tree, the compiler/library resources,
and the selected SDK when running locally on macOS. Pass the target, version,
and telemetry choice explicitly. Give each target its own output prefix.

Use a small fixed child environment instead of forwarding CI tokens, run IDs,
and unrelated shell variables. Nanocompile still keys every retained value.
Restore its artifact store with a target-specific Actions cache. Before
packaging, remove the generated binary and require a byte-identical restoration
and a recorded task hit. Signing and publishing remain outside the cache.

## Consequences

This is conservative whole-build reuse, not finer-grained compiler caching or a
measured speed improvement. A new version or changed input may miss. Inputs
are rehashed and artifact bytes are checked by nanocompile; the existing tests,
six-target matrix, signing, and release freshness checks remain required.
The source pin changes only after verification, not automatically with upstream
`main`. New build-time resources must join the explicit contract.
