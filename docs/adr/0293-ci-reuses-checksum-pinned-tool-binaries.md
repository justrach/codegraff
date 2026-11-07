# 0293: CI reuses checksum-pinned tool binaries

## Context

Building a cache tool in every release job adds work before it can reuse any
artifacts. The tool executable is independent of the release target: the Linux
matrix needs one host executable, not one build for every output architecture.

## Decision

Allow CI to download a prebuilt nanocompile executable from an optional HTTPS
object-store base URL supplied through repository configuration. Keep the
storage location out of source. Identify an object by source revision, Zig
version, host target, and SHA-256; verify the checked-in digest before making
it executable. A digest mismatch fails setup rather than trusting the store.

The initial host artifact uses the pinned source and Zig compiler, Linux
x86-64 baseline CPU features, static musl linking, and stripped debug data.
No local build paths or credentials belong in the uploaded artifact. Seeding
uploads only the executable; CI requires no write credentials for the store.

An unavailable object, unset location, unsupported host, or different Zig
version uses the existing pinned-source build. Release task caching and its
byte-identical restore verification remain unchanged. The benchmark requires
the downloaded executable so a silent source-build fallback cannot be reported
as a successful measurement of binary reuse.

## Consequences

Tool updates require building and checking a new artifact, publishing it under
its digest-qualified key, and reviewing the new pin together. An object-store
compromise alone cannot replace the executable accepted by CI. The source
fallback preserves availability but does not promise equivalent setup cost.
