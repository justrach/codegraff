# 0045. GLM 5.3-flash SWE via the Codegraff gateway

Status: accepted 2026-08-29

## Context

After ADR 0044 (skip learn auto-init on `-p`), SuperGrok grok-4.6 was
5/6 in 205s. The same suite was re-run on the Codegraff gateway
(`CODEGRAFF_API_KEY` → `gateway.codegraff.com/v1`) with `glm-5.3-flash`
on both `graff-dev` and `pi-codegraff`. Same key, same model, same
`--suite swe -j 6`. `glm-5.3-flash` is uncatalogued in graff so it
falls through to the gateway; do not pass `glm-5.3` (that row is zai
and `MissingKey`s without `ZAI_API_KEY`).

Pi needs `~/.pi/agent/models.json` provider `codegraff` pointing at
the gateway; `apiKey` is the env var name `CODEGRAFF_API_KEY`.

## Decision

Live A/B 2026-08-29 (`graff-evals/results/run-20260829-034235.jsonl`):

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 3/6 | 1353s | 6.9s | 90.5M | 96903 | 15085 | 19 |
| pi-codegraff | **5/6** | **758s** | 0.6s | 166.8M | 223771 | 27294 | 35 |

| task | graff | pi |
|---|---|---|
| map-conflict | ✓ 103s / 18k / 4 | ✓ 60s / 33k / 6 |
| validated | ✓ 164s / 46k / 10 | ✓ 26s / 21k / 5 |
| config-parse | ✓ 185s / 33k / 5 | ✓ 108s / 45k / 7 |
| json-stream | ✗ 300s timeout (no edit) | **✓ 117s / 43k / 7** |
| cookie-store | ✗ 300s timeout (no edit) | **✓ 301s / 44k / 5** |
| label-sort | ✗ 300s timeout | ✗ 146s / 37k / 5 |

Graff's three misses were SIGKILL at the 300s task cap before a
`[usage]` line. `json-stream` and `cookie-store` never wrote the
target file. Pi finished those. Both still miss `label-sort`.

This is not the 38s pin (already skipped; CPU stayed ~1–3s). GLM
flash through graff spent 3.5–7.5k output tokens on the tasks it
finished — the clock ran out on the rest. Pi's shorter catalog
completed the same model. Do not steal Pi's heap (167M vs 23–90M).

## Consequences

- Fair Codegraff A/B is `--model glm-5.3-flash` with `CODEGRAFF_API_KEY`.
- Next graff cut on this model is finishing inside 300s (fewer / shorter
  turns), not a catalog shrink to four tools.
- Rotate any `cg_sk_` pasted into a chat; do not commit it.
