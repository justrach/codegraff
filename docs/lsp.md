# Local language servers

LSP is **off by default**. Graff does not download servers, discover executable
project configuration, or run a server merely because a language is present.
An operator opts in through protected `.harness/settings.json`:

```json
{
  "lsp": {
    "servers": [{
      "id": "clangd",
      "command": ["/usr/bin/clangd", "--background-index=false"],
      "extensions": [".c", ".h", ".cpp", ".hpp"],
      "language_id": "cpp",
      "timeout_ms": 5000
    }]
  }
}
```

Use an already installed server and the language ID appropriate to the project.
The first configured server matching the file extension wins; a tool call may
select a configured server ID explicitly. Up to 16 servers are supported, with
100–30,000 ms deadlines and optional bounded warm session reuse (`warm_ttl_ms`:
`0` default one-shot, or `100–300,000` ms per-workspace idle TTL on POSIX). Commands are argv arrays, never shell interpolation.
Use absolute paths for custom server scripts that must also work in isolated
worker checkouts. Servers remain trusted local programs, not OS-sandboxed code;
they may read project configuration, run compiler probes, or write their own
caches. Grant only programs you trust. Python 3.9+ is required for the embedded
stdio client; no Python packages are needed.

## Operations

The optional native `lsp` tool supports `status`, `diagnostics`, `hover`,
`definition`, `references`, and `document_symbols`. On root sessions it stays
folded behind `load_tool_schemas` (or auto-loads on direct call, including in
plan mode) and is advertised only when servers were configured at trusted session
startup/adoption. Workers inherit eager access. The engine path is
the same for line REPL, ACP/Harness, RLM calls, and inherited worker tools.
`tool.use` policies on `lsp` and `--no-local-tools` also block execution.

Positions use **1-based lines and 0-based UTF-16 character offsets**. Source
files must exist, be UTF-8, and fit within 1 MiB. The client confines source
paths and returned location URIs to the agent's workspace, including symlink
checks; extra read roots are not LSP roots. It does not accept arbitrary server
methods, apply workspace edits, or invoke commands returned by a server.

Local CLI queries do not need a model or credentials:

```sh
graff lsp status
graff lsp diagnostics src/example.cpp
graff lsp hover src/example.cpp 8 12
graff lsp definition src/example.cpp 8 12
graff lsp references src/example.cpp 8 12
graff lsp document_symbols src/example.cpp
```

Results are versioned JSON. Empty diagnostics are clean **only after a current
server report**. Missing/stale diagnostics, timeout, unsupported methods, malformed
framing, or output limits are explicit incomplete/error outcomes, not success.
Hover/definition `null` can legitimately mean no symbol result. Locations outside
the workspace are filtered and marked. Results are capped at 64 KiB.

## Lifecycle and limitations

When `warm_ttl_ms` is `0` or omitted (the default), each query starts an owned,
bounded server session: initialize → initialized → didOpen → query/report →
shutdown/exit and cleanup. The process runner owns the entire process group/job,
including cancellation and descendants. Protocol framing, notifications and
server requests are bounded. Model/provider credentials are not deliberately
passed; the server uses the existing scrubbed tool environment.

By default, queries pay initialization cost instead of leaving background server
processes running. Setting `"warm_ttl_ms"` (`100`–`300000` ms) enables optional
POSIX per-`(workspace, server)` `AF_UNIX` session reuse (`0700` state directory,
`0600` socket) that tracks file SHA-256 hashes (`didOpen`/`didChange`),
serializes concurrent queries, and reaps the server process group on idle TTL
expiry. Cross-file references still depend on what the configured server can
index within the deadline; no whole-repository completeness is promised.
Diagnostics are on demand, not automatically attached after every edit.

Server registrations are immutable snapshots captured at root session startup
or ACP session adoption. Workers inherit those registrations; isolated child
settings cannot substitute a different executable. Detached workers deep-own the
snapshot. Explicit workspace switching does not silently replace trusted commands
in an existing agent. A new/adopted root session captures its selected workspace's
configuration. This does not change formatter behavior: formatting is not LSP.
