# 0044. Eval USD is xAI list price; hillclimb keeps only measured wins

Status: accepted 2026-08-30

## Context

`graff-evals/run.py` printed SuperGrok's `[usage]` `$0.0000` as the `usd`
column, and left grok-build's stream at `—`. That made every A/B a wash
on cost even when graff sent 3–6× the tokens (ADR 0024). The user asked
for an autoresearch-style hillclimb of grok-build vs graff, both on
grok-4.6, scored on wall, first-token latency, tool calls, tokens, and
total USD.

xAI list prices (2026-08): grok-4.6 is $2 / $0.50 / $6 per 1M under 200k
prompt tokens and $4 / $1 / $12 for the whole request at or above.
Hosted server-side tools add $5 / 1k for `web_search` / `x_search` /
`code_execution`. Graff's `in` includes cache reads; grok-build's
`input_tokens` does not.

0042 / 0043 are reserved by in-flight PRs on other branches.

## Decision

- Score every eval record at list price (`list_usd`), never the
  subscription footer. The formula matches `pricing.usdFor` /
  `graff-evals/list_price.py`.
- `hillclimb.py` proposes a harness change, reruns the same tasks, and
  keeps the change only when a majority of the five named axes improve
  and list-price USD does not get worse (unless pass rate also rose).
- Do not keep grok-build's heap (~165M RSS) or a 4-tool catalog
  (ADR 0024). Those are still rejected even if they win on tokens.

## Consequences

- SuperGrok sessions still bill $0 on the account; the table shows what
  the same tokens would cost on a metered key. See `graff-evals/hillclimb.py`.
- A live grok-build row requires a signed-in `grok` CLI. If that login
  is missing, the scorer still prices historical JSONL and the loop
  records the blocker instead of inventing a $0 wash.
- `x-search-off` is **not** a grok-build copy. Their 1.0.5 headless
  session still lists `web_search` / `web_fetch`. Hosted `x_search`
  stays on (ADR 0031).
- The 127M tax was `learn_bootstrap.copyExecutable` after five API
  calls, not hosted search. `-p` and the REPL share one learn-auto
  path: pin `graff-pinned` with a hardlink (copy only when the
  filesystem cannot). Do not skip bootstrap on oneshot — that split
  the surfaces. Do not chmod the pin (same inode as the live exe).
- Suite generation is the remaining ~38s tax. Session-end init is
  detached (ADR 0045); do not wait on it in `-p` / REPL / TUI.
