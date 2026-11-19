# 0349. Native Flint runtime remains external

Status: accepted 2026-11-16

## Context

A locally installed Zig/Metal inference server exposes an OpenAI-compatible API.
Treating it only as a custom router collides with Codegraff's reserved built-in
provider IDs and makes model discovery and context sizing awkward.

## Decision

Register a built-in `nanoattention` local provider for Flint, validate endpoint
overrides as loopback-only, and use the same resolved origin for chat and model
catalog requests. The inference runtime and checkpoint remain independently
installed; missing local credentials fail closed.

## Consequences

Users get native model routing without global router-file edits or bundled
weights. Runtime installation and configuration remain the user's responsibility,
and the built-in provider does not imply a cloud service or performance guarantee.
