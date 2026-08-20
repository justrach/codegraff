# 0014. `edit_file` is grok-build `search_replace`

Status: accepted 2026-08-20

## Context

Grok-build's file-edit surface is two tools: `search_replace` (exact unique
span, optional `replace_all`, MultiEdit as a wrapper) and `hashline_edit`
(LINE:HASH anchors compiled down to the same splice). A same-account
comparison (2026-08-19) asked whether graff should grow those names.

Graff already has the first tool: `edit_file` takes `path`, `old_string`,
`new_string`, `replace_all`, and batched `edits`. Adding `search_replace` as
a second catalog name, or shipping hashline anchors, would look like "more
parity" and would split the model's write path.

## Decision

- `edit_file` *is* grok `search_replace` / OpenCode `edit`. Same unique-match
  default, same `replace_all`, same "mention `read_file`" on a miss. Do not
  advertise a second name.
- Empty `old_string` does **not** create a file. That grok default is a
  create/overwrite footgun; graff creates with `write_file`.
- `old_string == new_string` is refused (grok does this; a no-op splice used
  to report success).
- Splice is byte-exact. Do not adopt grok's optional unicode-confusable
  fallback, gitignore edit block, or LF-old-string matching a CRLF file.
- Do not add `hashline_edit`. Anchors are grok's LINE:HASH scheme; graff's
  numbered `read_file` plus exact `edit_file` is the equivalent.

The cases live in `src/edit_grok_contract.zig`, driven through `exec.execTool`
so the catalog name is what is tested. A miss includes a nearest-match line
when a token from `old_string` appears in the file (`src/edit_hint.zig`).

## Consequences

A model that learned grok's search/replace shape already has the tool; it
must use `edit_file` and `write_file` instead of an empty-old create. Revisit
only if a host requires the grok tool names on the wire. A second catalog or
process-wide `chdir` is still out (ADR 0006, ADR 0012).
