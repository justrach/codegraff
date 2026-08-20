# 0012. WebAssembly ships the kernel cube, not the agent

Status: accepted 2026-08-20

## Context

fx compiles two `wasm32-freestanding` artifacts (`fx-core.wasm`, `fx-term.wasm`)
and a JS host that supplies fetch, session storage, and (optionally) exec. The
WASM build has no native processes, OS sandbox, WASI filesystem, MCP, or
subagents; JSPI is required for the async host calls.

graff's live loop (`std.http.Client`, `bash` jobs, MCP stdio, TTY restore)
does not compile to freestanding WASM as-is, and grafting a host layer onto
every I/O seam is a second product. The kernels already are total functions
over finite cubes (`{0,1}^6` catalogs, lexical paths) with no OS.

## Decision

`zig build wasm` produces `graff-kernel.wasm`: `catalog`, `advertised`, and
`confined` over the same fixtures Lean exports. The JS host is
`sdk/wasm/graff-kernel.js`. It does not use JSPI.

A later `graff-core.wasm` / `graff-term.wasm` needs an explicit host
capability table (fetch, workspace, no implicit bash), the same way fx does.
Do not compile `src/main.zig` to WASM and hope.

Do not target WASI so the module can load in a browser without a filesystem
polyfill. Do not emit `OSC 50` or claim the pager font is ours.

## Consequences

The wasm step is a compile-only tier-1 check (`zig build wasm`). Semantics
stay in the native suite against `spec/kernels/*.json`. Full-agent embed
stays `graff serve` + the remote SDK until a host layer exists.
