# grok-4.6 list-price baseline: graff vs grok-build

Axes: wall, first-token latency, tool calls, tokens (uncached + cached + out),
xAI list-price USD (`$2/$0.50/$6` per 1M under 200k prompt tokens; `$4/$1/$12`
for the whole request at or above). SuperGrok's `[usage]` `$0.0000` is ignored.

Graff `[usage] in` includes cache reads. grok-build `input_tokens` does not —
ADR 0024's "185k in" column was uncached-only and undercounted grok-build.

## Live 2026-08-30 (`run-20260830-034621.jsonl`)

Same SuperGrok / grok OAuth, grok-4.6, one rep, three core tasks
(`exact-reply`, `file-ops`, `fix-fib`). grok-build 1.0.5 signed in via
device-code.

| harness | pass | wall | first | calls | tokens | uncached | cached | out | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| graff-dev (x_search on) | 3/3 | 64.0s | 2.7s | 9 | 36,374 | 14,757 | 20,352 | 1,265 | $0.0473 | 91.3M |
| **graff-dev-noxsearch** | 3/3 | **54.5s** | **1.7s** | 9 | **22,482** | 6,183 | 15,616 | 683 | **$0.0243** | 91.3M |
| grok-build | 3/3 | **41.6s** | 3.6s | **8** | 132,858 | 31,184 | 100,352 | 1,322 | $0.1205 | 153.8M |

| task | graff wall / $ | noxsearch wall / $ | grok wall / $ |
|---|---:|---:|---:|
| exact-reply | 3.98s / $0.0075 | **2.09s / $0.0038** | 6.64s / $0.0149 |
| file-ops | 7.76s / $0.0129 | **5.05s / $0.0075** | 9.32s / $0.0426 |
| fix-fib | 52.22s / $0.0269 | 47.40s / $0.0129 | **25.68s / $0.0630** |

**Iteration `x-search-off`: KEEP.** vs champion: wall −15%, first-token −38%,
tokens −38%, list$ −49%, calls wash, pass 3/3, RSS unchanged. Promoted onto
the `graff-dev` / `graff` eval harnesses (`GRAFF_XAI_X_SEARCH=0`). Product
default stays on (ADR 0031). Heap and catalog untouched.

grok-build still wins **summed wall** (fix-fib 26s vs 47s) and one fewer
call. It loses list$ and tokens once cache reads are counted (132k vs 22k).
Next chase is fix-fib wall, not their RSS.

## Historical rescore (same-day paired JSONL)

### SWE, 2026-08-25 (`run-20260825-061731.jsonl`) — the ADR 0024 grok-inclusive file

| harness | pass | wall | first | calls | tokens | uncached | cached | out | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 4/6 | 742.7s | 4.9s | 96 | 1,307,858 | 250,788 | 1,008,640 | 48,430 | $1.9527 | 9.1M |
| grok-build | **5/6** | **500.2s** | **3.4s** | **39** | **1,062,104** | 184,880 | 845,184 | 32,040 | **$1.4561** | 164.6M |

Grok-build wins every named axis except RSS (18×). The old "185k vs 1.3M in"
headline was an accounting mismatch; honest totals are 1.06M vs 1.31M.

### After prompt/subagent cuts — 2026-08-28

Shared tasks only. `cookie-store` on graff-dev that day has no `[usage]` line
(fail / empty tally) so its list$ is $0 and understates graff spend.

**core** (`run-20260828-021606.jsonl`, 11 tasks)

| harness | pass | wall | first | calls | tokens | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 11/11 | **89.4s** | **1.9s** | 38 | **147,831** | **$0.1812** | **9.1M** |
| grok-build | 11/11 | 140.9s | 2.9s | **33** | 536,768 | $0.4591 | 155.7M |

**rlm** (`run-20260828-021008.jsonl`, 5 tasks)

| harness | pass | wall | first | calls | tokens | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 5/5 | **45.6s** | **3.6s** | **18** | **71,991** | **$0.0908** | **8.6M** |
| grok-build | 5/5 | 119.8s | 4.5s | 22 | 445,201 | $0.5042 | 159.5M |

**swe** (`run-20260828-020830.jsonl`, 6 tasks)

| harness | pass | wall | first | calls | tokens | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|---:|
| graff-dev | 4/6 | **224.9s** | **1.8s** | **25** | **135,455** | **$0.2209** | 62.9M |
| grok-build | **5/6** | 330.2s | 2.7s | 27 | 533,397 | $0.5576 | 156.1M |

## What the hillclimb is allowed to chase

On 2026-08-25 SWE, grok-build still wins pass / wall / latency / calls / USD.
On 2026-08-28, graff wins cost and tokens once cache is counted, and still
loses a SWE pass (`cookie-store` / historically `json-stream` / `label-sort`).
Do not steal the 165M heap or a 4-tool catalog to close the remaining gap
(ADR 0024). First candidate: `GRAFF_XAI_X_SEARCH=0` (`graff-dev-noxsearch`).
