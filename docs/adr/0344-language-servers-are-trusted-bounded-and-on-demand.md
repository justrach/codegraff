# ADR 0344: language servers are trusted, bounded, and on demand

Status: accepted

## Context

Formatting and text indexing do not provide compiler-backed diagnostics, hover,
definitions, or references. Adding those capabilities must not implicitly
execute project-supplied code, download a server, or change every model catalog.
A persistent IDE-style server also introduces document synchronization, worker
ownership, workspace-switch identity, and shutdown obligations that are larger
than a first read-only LSP integration.

## Decision

- Server registrations come from write-protected user defaults
  (`$HOME/.graff/lsp/settings.json` or `GRAFF_LSP_CONFIG`) merged under
  protected workspace `.harness/settings.json`, up to 16 servers. Project entries
  override matching global server IDs, and `"lsp": false` opts a workspace out
  entirely. When neither exists, both the catalog and execution capability stay
  off; `graff lsp setup [--check]` is an explicit CLI step that checks `PATH`
  first, installs missing standard servers into isolated `$HOME/.graff/lsp/`,
  and writes the global defaults. Both `.harness/settings.json` and `.graff/lsp`
  are write-protected against model edits.
- A native optional `lsp` tool and model-free local CLI share one engine executor.
  REPL, ACP/Harness, RLM, and worker dispatch use that same path; on root sessions
  `lsp` stays folded behind `load_tool_schemas` until needed. Existing
  `tool.use` policies and `--no-local-tools` remain backstops.
- Default `languageId` inference maps `.ts`/`.mts`/`.cts` to `typescript`,
  `.tsx` to `typescriptreact`, `.js`/`.mjs`/`.cjs` to `javascript`, and `.jsx`
  to `javascriptreact`.
- Server registrations are immutable per-agent snapshots. Child worktrees
  cannot substitute their own commands; detached workers deep-own the snapshot.
  A newly adopted ACP root captures its selected workspace's configuration.
- By default (`warm_ttl_ms = 0`) each call uses an owned one-shot stdio JSON-RPC
  session (100–30,000 ms timeout): initialize, didOpen, read-only operation/current
  diagnostics, shutdown and process-tree cleanup. Operators may opt into bounded
  per-workspace POSIX session reuse (`warm_ttl_ms`: 100–300,000 ms), which tracks
  document SHA-256 hashes (`didOpen`/`didChange`) and reaps the server process
  group when idle.
  The client supports diagnostics, hover, definitions, references and document
  symbols; it never applies workspace edits or executes server commands.
- An embedded, standard-library Python 3.9+ helper implements Content-Length
  framing and bounded pipe readers. The engine's existing process runner owns
  the helper and server descendants, timeout and cancellation. The helper is
  shipped as source bytes, not a separately downloaded executable.
- Files and returned locations stay within the agent workspace. Source,
  protocol frames, event counts, stderr and final output are bounded. Source
  positions use 1-based lines and 0-based UTF-16 character offsets at the tool
  boundary, converted to LSP's zero-based lines internally.
- No current diagnostic report is not a clean report. Timeouts, unsupported
  operations, stale reports and truncation remain explicit incomplete/errors.
  Diagnostics are requested on demand, not appended after every write.

## Trade-offs and alternatives

One-shot calls pay server startup/indexing costs and cannot promise a complete
whole-workspace reference index within a short deadline. They avoid hidden
persistent processes and stale document state while keeping ownership testable.
A reusable session manager can replace the transport later without changing the
read-only tool contract, once its lifecycle and per-worker identity are proven.

A pure Zig protocol client would remove Python as an opt-in runtime dependency,
but would duplicate framing, interleaved RPC and cross-platform pipe machinery
in this first iteration. The bounded helper is explicit and testable against
real installed servers; no third-party Python packages are required. Server
programs themselves remain trusted local executables, not an OS sandbox.

Compiler subprocess output alone was rejected as an LSP substitute: real-server
fixtures exercise initialize/didOpen, diagnostic notifications/pull reports,
hover and definitions. Performance/quality comparisons use external graders
and report whether LSP was actually exercised, rather than relabeling a
formatter-only benchmark as an LSP result.
