# 0038. In-process ACP core is the fx-shaped embed

Status: accepted 2026-08-26

## Context

v0.0.279 parked WASM / `libgraff` / in-process Zig. The host recipe that
shipped is subprocess (`graff acp`, `@codegraff/sdk/acp`) — OpenCode's
shape. fx's embed is same-process: `libfx` + `fx-core.wasm` +
`createFxAgent()`. That is the frontier the 279 continuation was asked
to enable.

Compiling the full agent loop (HTTP, bash, git, Zig `Io.Threaded`) to
wasm32 is a different product. The ACP loop is already a `TurnFn` plus
JSON-RPC writers.

## Decision

Same-process embed is an ACP **core**, not the full CLI:

- `src/acp_engine.zig` is the initialize / session/new / prompt / cancel
  loop. It does not import `main.zig` or `Agent`.
- `libgraff` (shared library) and `graff-core.wasm` export the same C ABI
  (`graff_acp_create` / `graff_acp_feed` / in-out slots).
- `@codegraff/sdk/embed` `createGraffAgent()` instantiates the wasm in
  the host isolate. No child process.
- First-slice turn is `echo:` (protocol proof). Live tools, TLS, and
  bash stay on `graff acp` until a host-imported turn exists.
- Subprocess ACP remains the hosted coding agent (ADR 0032).

This record shipped on `main` via #645 after the v0.0.279 tag.

## Consequences

A JS host can run the ACP handshake in-process the way fx does. It
cannot yet run a model turn inside the wasm. Do not replace `graff acp`
with the core for Zed or `apps/native`. Revisit when a host `turn`
import (JSPI or native addon) is wired.
