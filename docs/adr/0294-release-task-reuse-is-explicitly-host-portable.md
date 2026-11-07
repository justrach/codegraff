# 0294: Release task reuse is explicitly host-portable

## Context

A declared task can miss after its artifacts are restored because compatible
runners have different native CPUs or kernel versions. Separately, invoking
`zig build --fetch=all` can compile the native build runner even when the
complete dependency tree is already available. Neither cost is artifact
restoration itself.

## Decision

Keep native host identity as nanocompile's default. The release workflows
explicitly opt their audited Linux x86-64 host tasks into platform identity,
which retains host OS, architecture and ABI partitions but not native CPU
features or kernel versions. Commands specify the release target, version,
optimization, and baseline target CPU. Source files, complete dependency
contents, compiler/resources, paths, environment and outputs remain keyed.

The release build and pinned dependency build scripts pass the selected target
to every imported module; the CLI-only release step has no host-derived code
generator or host-selected system library. A future build change introducing
native CPU/kernel selection or other host-dependent outputs must remove this
opt-in or declare and partition those influences before reusing tasks. A fixed
compiler target alone is not proof of host independence.

After a successful full dependency fetch, save a readiness snapshot containing
the compiler binary digest, root manifest digest and complete dependency file
membership/content digests. Reuse it only when the actual snapshot matches.
Manifest/compiler changes and package edits, additions or removals trigger the
normal full fetch. Do not use timestamps as proof, and do not fast-path hidden
directory membership behind symlinks. Cache the package tree with the build
caches so a fresh runner can validate that snapshot.

The readiness record is only a preparation hint, not authority to reuse a
binary: nanocompile still freshly hashes every declared source input and
validates restored artifacts. Native builds and local invocations remain
native-sensitive unless the caller explicitly opts in.

## Consequences

The release wrapper avoids redundant native preparation without weakening
general-purpose task caching. Cross-runner reuse remains tied to stable paths,
tools and environment; it is not relocatable or a claim of build hermeticity.
Cold builds still pay preparation costs, and direct Zig cache hits can still
be cheaper than whole-task validation.
