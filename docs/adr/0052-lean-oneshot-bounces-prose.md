# 0052. Lean `-p` bounces a first-turn prose-only "done"

Status: accepted 2026-08-29

#675 numbered this 0048. 282 already owns 0048 (HTTP client generations);
this cut remaps the record.

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

## Confirm — `deepseek-v4-flash` after bounce (`run-20260829-063114.jsonl`)

Same `--suite swe -j 6` seat as ADR 0047.

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | **4/6** | 250s | 0.03s | 91.2M | 170k | 25k | 26 |

| task | before (0047) | after |
|---|---|---|
| cookie-store | ✓ 91s / 8 | ✓ 133s / 7 |
| config-parse | ✓ 33s / 4 | ✗ 5s / 1* |
| label-sort | ✗ 63s / 6 | ✗ 5s / 1* |
| map-conflict | ✗ 4s / 1 | ✓ 20s / 5 |
| json-stream | ✗ 4s / 1 | ✓ 65s / 8 |
| validated | ✗ 4s / 1 | ✓ 20s / 4 |

\*follow-up API error under `-j 6` (resp 110 B, ~450 ms). Isolated
serial retry (`run-20260829-063451.jsonl`): `config-parse` ✓ 48s / 5,
`label-sort` ✗ 62s / 5 (check, exit 0). Do not stitch that into 5/6.

The confirm run used tools on the first call (lean intro). Bounce is
the backstop when the model writes "I fixed it" with zero tools. No
`fake_done` notes on this run.

## Consequences

- `graff -p "what is 2+2"` pays one extra call if the first reply has
  no tool. Acceptable for a coding harness.
- Interactive REPL / TUI / `--no-lean` / subagents are unchanged.
- Revisit if a named flash model needs `tool_choice=required` on the
  first call; do not restore a global force.
- Follow-up `-j 6` flakes and the OpenCode A/B are ADR 0053 (graff
  5/6 in 362s after the retry).
