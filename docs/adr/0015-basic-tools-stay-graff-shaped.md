# 0015. Basic tools stay graff-shaped

Status: accepted 2026-08-20

## Context

After locking `edit_file` to grok `search_replace` (ADR 0014), the same
comparison asked whether `read_file` and the other basic tools should grow
grok's loops: sparse line numbers, CRLF-stripped display, `offset`/`limit`,
a 1000-line default, built-in PDF/PPTX, `list_dir`, `grep`, OpenCode `write`
mkdir-p, and a persistent bash cwd.

Graff already has the jobs those tools do. Changing the read loop to look
like grok's would break the edit contract: `edit_file` needs the bytes
`read_file` returned, not a pretty projection.

## Decision

- **`read_file` loop does not change.** Whole-file and `start_line`/`end_line`
  windows are byte-exact (CRLF kept, no injected numbers). `contains` is the
  numbered lookup; `compact` is the lossy codedb view. Do not add
  `offset`/`limit` aliases (limit is a count; `end_line` is inclusive).
  Negative `start_line` clamps to 1; it is not grok's from-end offset.
- **PDF / PPTX / jupyter stay bash converters** (`pdftotext`, …). Images
  already stage via the vision path. Do not embed document extractors.
- **`write_file` does not mkdir -p.** Missing parent is an error; create
  the directory with bash. Overwrite is the create path (ADR 0014).
- **`bash` / `bash_output` / `bash_kill` / `monitor` stay as shipped.**
  Do not persist cwd across calls (ADR 0006). Do not add grok `grep` or
  `list_dir` — that is `codedb` plus bash.
- **`webfetch` stays one URL in.** Do not copy grok's client-side fetch zoo.

Cases: `src/basic_grok_contract.zig`, through `exec.execTool`.

## Consequences

A model that learned grok `read_file` must use `path` +
`start_line`/`end_line` (or `contains`), not `target_file`/`offset`/`limit`.
Revisit only if a host requires those names on the wire. A second catalog
is still out (ADR 0012).
