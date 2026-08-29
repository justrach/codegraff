# 0044. `-p` and `--json` skip learn auto-init

Status: accepted 2026-08-29

## Context

ADR 0043 ran Pi on the same SuperGrok SWE seat as graff-dev. Tokens and
calls were a wash (30 vs 31). Pi's wall was 276s vs graff's 456s. That
gap is not Pi's 4-tool catalog.

Every graff-dev SWE task made exactly 5 API calls — the
`learn_auto` bootstrap floor — then `startBackgroundLearning` copied
132M `.graff/learn-kit/graff-pinned` and generated suites. `cpu_sample_s`
was 38.3–38.5s on every task; Pi's was ~1s. Subtract that tax and
model-wait (wall − CPU) matches or beats Pi on 5/6 tasks:

| task | graff wall − CPU | Pi wall − CPU |
|---|---:|---:|
| map-conflict | 21s | 15s |
| validated | 26s | 25s |
| label-sort | 39s | 37s |
| json-stream | 42s | 48s |
| cookie-store | 48s | 101s |
| config-parse | 50s | 44s |

Pi's extra pass is still the `json-stream` whitespace-only json-seq
clause (ADR 0024). Both miss `label-sort`. The same 38s copy is why
`test-learn-auto-init.py`'s 45s exit wait flakes on CI.

## Decision

`startBackgroundLearning` is a no-op when `unattended` (`-p`) or
`--json`. Interactive REPL/TUI/ACP still auto-init after 5 model calls.
`GRAFF_LEARN_AUTO=off` still kills the whole trigger. `graff learn init`
is unchanged.

Do not steal Pi's catalog or heap. Do not treat Pi `first_out_s` as a
TUI steal.

## Consequences

- `graff -p` / eval sandboxes no longer write 132M or spend ~38s of
  local CPU on the way out. Interactive workspaces still earn a store.
- The CI learn-auto probe is an interactive PTY session; it still
  copies the pin. A later cut can speed that copy. Do not raise its
  timeout to hide the tax.
- Revisit if a one-shot should ever seed learning (it should not: the
  sandbox is thrown away).

## Confirm (2026-08-29, after this revision)

`graff-evals/results/run-20260829-031139.jsonl`, SuperGrok grok-4.6,
`--suite swe --harness graff-dev -j 6`. No `graff-pinned`. Sandbox
100–164K.

| harness | pass | wall (sum) | first | RSS | in | out | calls | CPU |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| before (0043) | 4/6 | 455.5s | 2.6s | 91.3M | 161066 | 11590 | 30 | 230s |
| after | **5/6** | **205.2s** | 2.5s | 90.8M | 159700 | 11351 | 30 | **6.5s** |

| task | after |
|---|---|
| map-conflict | ✓ 17s / 25k / 5 |
| validated | ✓ 19s / 24k / 5 |
| label-sort | ✗ 34s / 26k / 5 |
| config-parse | ✓ 40s / 27k / 5 |
| json-stream | **✓ 47s / 27k / 5** |
| cookie-store | ✓ 47s / 30k / 5 |

Wall **−55%**, CPU **−97%**, same tokens/calls. `json-stream` passed
this rep: the model kept "no RS → empty" instead of inventing a
missing-delimiter raise (the 0043 miss). That is one-rep model noise,
not a catalog gap — Pi's earlier 5/6 was the same clause, not a
smarter loop. `label-sort` still fails (hidden natural-order /
leading-ws); grok-build and Pi miss it too. RSS ~91M is the process,
not the pin. Pi could not re-run here (OAuth bearer 403 as `XAI_API_KEY`).
