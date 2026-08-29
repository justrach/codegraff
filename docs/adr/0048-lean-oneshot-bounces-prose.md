# 0048. Lean `-p` bounces a first-turn prose-only "done"

Status: accepted 2026-08-29

## Context

ADR 0047 ran Codegraff `deepseek-v4-flash` SWE. Pi 5/6 in 492s. Graff
2/6 in 199s. The three misses (`map-conflict`, `json-stream`,
`validated`) were 4-second one-call replies (~1.5k in / ~160 out) that
described a patch and never called a tool. An isolated retry of those
three recovered two. Same miss as everyone on `label-sort`.

Empty-completion retry only covers whitespace. A 158-token "I fixed
it" ends the turn. Forcing `tool_choice=required` is already reserved
for `--strict` / `--eval`; DeepSeek thinking mode has rejected it
before. Do not steal Pi's four-tool catalog (ADR 0024).

## Decision

On lean `-p` (unattended, file tools advertised, not review, not a
subagent), a first-turn completion that has text and zero tool calls
is not done. Append one user bounce naming `read_file` / `edit_file` /
`write_file` and re-open the loop. One bounce only (`model_calls == 1`).

Lean intro also says a file change described in prose is not done.

## Consequences

- `graff -p "what is 2+2"` pays one extra call if the first reply has
  no tool. Acceptable for a coding harness.
- Interactive REPL / TUI / `--no-lean` / subagents are unchanged.
- Revisit if a named flash model needs `tool_choice=required` on the
  first call; do not restore a global force.
