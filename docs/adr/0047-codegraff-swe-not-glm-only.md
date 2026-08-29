# 0047. Codegraff SWE A/B is not GLM-only

Status: accepted 2026-08-29

## Context

ADR 0044 (learn skip) and ADR 0046 (`reasoning_effort=low` + streaming
`-p`) made SuperGrok grok-4.6 and Codegraff `glm-5.3-flash` look like
the harness, not Pi's catalog. That could have been those two models.
The same `--suite swe -j 6` seat (`CODEGRAFF_API_KEY` →
`gateway.codegraff.com/v1`, `graff-dev` vs `pi-codegraff`) was re-run
on DeepSeek flash, Gemini flash, and Kimi k2.6.

Fair A/B is the same key and the same model id. Pi needs those ids in
`~/.pi/agent/models.json` under provider `codegraff`. Keep Pi on stock
defaults. Do not steal its 4-tool catalog or 165M heap.

Graff `first_out` is the stderr `calling` line (~0.03s), not gateway
TTFT. Pi `first` is the JSONL `session` line (~0.6s), not TUI paint.

## Decision

Record the 2026-08-29 runs. They do not change the keep-list, effort
routing, or learn skip. A second full DeepSeek suite (`060536`) hit a
burnt gateway (0-token) and is not evidence.

## Confirm — `deepseek-v4-flash` (`run-20260829-055625.jsonl`)

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 2/6 | 199s | 0.03s | 91.1M | 132k | 22k | 21 |
| pi-codegraff | **5/6** | 492s | 0.7s | 186.4M | 480k | 56k | 46 |

| task | graff | pi |
|---|---|---|
| cookie-store | ✓ 91s / 71k / 8 | ✓ 149s / 162k / 11 |
| config-parse | ✓ 33s / 16k / 4 | ✓ 121s / 132k / 10 |
| label-sort | ✗ 63s / 40k / 6 | ✗ 108s / 58k / 5 |
| map-conflict | ✗ 4s / 2k / 1 | ✓ 31s / 35k / 6 |
| json-stream | ✗ 4s / 2k / 1 | ✓ 58s / 62k / 8 |
| validated | ✗ 4s / 2k / 1 | ✓ 24s / 32k / 6 |

Graff's three 4s misses were one-call no-edits, not 300s hangs.
Isolated retry of those three (`run-20260829-060322.jsonl`):
`map-conflict` ✓ 28s / 6, `json-stream` ✓ 126s / 9, `validated` still
✗ 3s / 1. DeepSeek flash often answers without tools on graff's lean
catalog; Pi's shorter catalog finishes. Same `label-sort` miss.

## Confirm — `gemini-3.7-flash` (`run-20260829-055900.jsonl`)

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | **5/6** | **103s** | 0.04s | 91.1M | 64k | 20k | 19 |
| pi-codegraff | 0/6 | 35s | 0.6s | 166.4M | 42k | 0.5k | 18 |

| task | graff | pi |
|---|---|---|
| map-conflict | ✓ 9s / 8k / 3 | ✗ 5s / 7k / 3 |
| validated | ✓ 12s / 7k / 3 | ✗ 8s / 7k / 3 |
| json-stream | ✓ 13s / 10k / 4 | ✗ 5s / 7k / 3 |
| config-parse | ✓ 20s / 11k / 3 | ✗ 5s / 7k / 3 |
| label-sort | ✗ 20s / 11k / 3 | ✗ 5s / 7k / 3 |
| cookie-store | ✓ 29s / 17k / 3 | ✗ 8s / 7k / 3 |

Pi's Gemini tool loop dies after the first tool (empty assistant
`message_end`; `codegraff-gemini-echo` was installed). That column is
not a fair A/B. Graff's 5/6 in 103s is the real flash confirm — same
`label-sort` miss as GLM / grok / Pi.

## Confirm — `kimi-k2.6` (`run-20260829-055930.jsonl`)

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | **4/6** | 583s | 0.04s | 91.1M | 62k | 21k | 22 |
| pi-codegraff | 2/6 | 346s | 0.6s | 161.4M | 73k | 13k | 17 |

| task | graff | pi |
|---|---|---|
| validated | ✓ 31s / 9k / 4 | ✗ 1.3s / 0 tok |
| map-conflict | ✓ 47s / 11k / 4 | ✗ 1.3s / 0 tok |
| config-parse | ✓ 61s / 24k / 7 | ✓ 125s / 40k / 7 |
| json-stream | ✗ 103s / 3k / 2 | ✗ 1.2s / 0 tok |
| cookie-store | ✓ 161s / 4k / 2 | ✓ 97s / 8k / 3 |
| label-sort | ✗ 179s / 12k / 3 | ✗ 121s / 25k / 4 |

Pi's three 1.2s zeros never reached the model (retry stayed 0-token).
Kimi thinks on a `pong` even with Pi `reasoning: false`. Graff still
finished four tasks on ~91M RSS.

## Already recorded (same suite)

| model | seat | graff | pi | ADR |
|---|---|---|---|---|
| grok-4.6 | SuperGrok / `pi-xai` | 5/6 in 205s | 5/6 in 276s | 0044 |
| glm-5.3-flash | Codegraff | **5/6 in 286s** | 5/6 in 758s | 0046 |
| gemini-3.7-flash | Codegraff | **5/6 in 103s** | (tool-loop dead) | this |
| kimi-k2.6 | Codegraff | 4/6 in 583s | 2/6 (3× API zero) | this |
| deepseek-v4-flash | Codegraff | 2/6 in 199s* / **4/6 in 250s** (0048) | **5/6 in 492s** | this |

\*three 1-call no-edits; isolated retry recovered `map-conflict` and
`json-stream`. Do not stitch that into the suite score.

## Consequences

- GLM 5/6 in 286s vs Pi 758s is not a one-off on flash: Gemini graff
  is 5/6 in 103s on the same suite.
- DeepSeek flash is the exception: Pi's catalog finishes; graff's lean
  8-tool still one-shots. Bounce that prose-only first turn (ADR 0048).
  Do not steal the four-tool catalog to "fix" it.
- Pi + Gemini on this gateway is not a usable A/B until Pi's tool
  follow-up is fixed. That is not a graff TUI steal.
- `label-sort` still fails across models. Do not chase it.
- A burnt gateway (0-token / 1s exits) is not a model result. Re-run
  the suite; do not average it in.
