# 0043. Pi SWE A/B uses the same SuperGrok seat via pi-xai

Status: accepted 2026-08-28

## Context

ADR 0024 compared graff vs grok-build on `--suite swe`. Pi was already
wired as `pi` (OpenAI/luna) and `pi-codegraff` (Gemini gateway), so it
never sat on the SuperGrok login those numbers used. A follow-up asked
to run Pi the same way, and whether that run says we can go faster.

## Decision

`pi-xai` is the same-seat harness: `graff-evals/pi-xai.sh` maps
`~/.xai/credentials/graff-oauth.json` into `XAI_API_KEY` and execs
stock `pi -p --mode json --provider xai --model {model} --no-session`.
Fair A/B is `--suite swe --harness graff-dev,pi-xai --model grok-4.6`.
Keep Pi on stock defaults (4-tool catalog, thinking on).

Live A/B 2026-08-28 (`graff-evals/results/run-20260828-164346.jsonl`,
SuperGrok grok-4.6, `-j 6`, one rep):

| harness | pass | wall (sum) | first | RSS | in | out | calls | $ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 4/6 | 455.5s | 2.6s | 91.3M | 161066 | 11590 | 30 | $0.0000 |
| pi-xai | **5/6** | **275.5s** | 0.9s | 165.5M | 186368 | 6501 | 31 | $0.1344 |

| task | graff | pi |
|---|---|---|
| config-parse | ✓ 89s / 28k / 5 | ✓ 45s / 27k / 5 |
| cookie-store | ✓ 86s / 31k / 5 | ✓ 102s / 44k / 6 |
| json-stream | ✗ 80s / 26k / 5 | **✓ 49s / 42k / 6** |
| label-sort | ✗ 77s / 26k / 5 | ✗ 38s / 22k / 4 |
| map-conflict | ✓ 60s / 25k / 5 | ✓ 16s / 26k / 5 |
| validated | ✓ 64s / 26k / 5 | ✓ 26s / 27k / 5 |

Pi's extra pass is `json-stream` whitespace-only json-seq — the same
spec-contract miss ADR 0024 already named (grok-build passed it). Both
miss `label-sort`. Tokens and calls are a wash. Pi `first_out_s` is the
first JSONL `session` line, not TUI first paint; graff's is the first
progress line. Pi `$` is list-price; graff SuperGrok is flat-rate.

**Reject:** Pi's 4-tool catalog (ADR 0024 already measured an rlm-only
keep-list fail). Pi's 165M heap. Treating `first_out` as a TUI steal.

**Next cut (not this revision):** every graff-dev SWE sandbox wrote
127M `.graff/learn-kit/graff-pinned` (a copy of the binary). Pi's
sandbox is ~8K. That is a one-shot tax; skip auto-init on `-p` if we
want the next wall/RSS drop. TUI leftover after the early alt-screen
claim is first chrome, not another escape.

## Consequences

- `pi-xai` is the SuperGrok Pi harness. `pi` / `pi-codegraff` stay the
  OpenAI / Gemini seats.
- Do not raise a catalog or heap change from one Pi pass on
  `json-stream`.
- Revisit the learn-kit pin on `-p` when we want the next speed cut.
