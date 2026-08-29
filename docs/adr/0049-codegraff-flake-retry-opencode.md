# 0049. Retry short Codegraff follow-up flakes; OpenCode A/B on the same seat

Status: accepted 2026-08-29

## Context

ADR 0048 bounced lean `-p` prose-only first turns. DeepSeek flash SWE
moved 2/6 → 4/6. The leftover miss besides `label-sort` was
`config-parse` dying in ~5s after a successful 4-tool first batch: a
~110-byte / ~450 ms `api_error` under `-j 6`. Isolated serial retry
passed. Overload / `server_error` needles did not match. A missing
`error.message` becomes `unknown error` (`apiErrorMessage`).

Same-seat OpenCode was missing from `graff-evals`. Fair A/B is the
same `CODEGRAFF_API_KEY` → `gateway.codegraff.com/v1`. Do not steal
Pi's four-tool catalog (ADR 0024) or OpenCode's ~1G heap.

## Decision

- Treat short generic envelopes (`unknown error`, `Internal Server
  Error`, empty `api_error`) and tiny unparseable bodies (≤256 B) as
  bounded retries (2). `invalid_request` / auth / quota / not-found
  stay fail-fast.
- Add `opencode-codegraff` (`opencode run --auto --format json` +
  tracked `opencode-codegraff.json`). Do not commit OpenCode auth.
- Eval failures keep a 400-byte `stderr_tail` so the next envelope is
  visible.

## Confirm — `deepseek-v4-flash` (`run-20260829-072310` + `072758`)

Same `--suite swe -j 6` seat as ADR 0047 / 0048.

| harness | pass | wall (sum) | first | RSS | in | out | calls |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev (`072758`) | **5/6** | 362s | 0.05s | 91.1M | 346k | 38k | 38 |
| opencode-codegraff (`072310`) | **5/6** | 261s | 3.6s | 1064M | 61k | 8k | 36 |
| pi-codegraff (0047) | **5/6** | 492s | 0.7s | 186M | 480k | 56k | 46 |

The parallel A/B (`072310`) still had graff 4/6 (`config-parse` 5s /
1). After the `unknown error` / tiny-body retry, graff `072758` is
5/6; `config-parse` ✓ 30s / 4. Same `label-sort` miss on all three
harnesses. Do not stitch the two graff suite scores.

OpenCode `first` is the first JSONL event (~3.6s), not TUI paint.
Graff `first` is the stderr `calling` line. Do not treat 0.05s as a
TUI steal.

## Consequences

- Score is now tied with Pi and OpenCode. Wall is not: OpenCode 261s
  vs graff 362s is mostly `cookie-store` variance (89s on `072310`,
  185s on `072758`). RSS stays ~91M; do not take OpenCode's heap.
- Revisit if a named 400 should retry; do not retry `invalid_request`.
