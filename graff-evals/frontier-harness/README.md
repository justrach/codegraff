# FrontierHarness TB-21 (graff vs exo vs published K3)

Same 21 terminal-bench tasks as [runta-dev/frontier-harness-eval](https://github.com/runta-dev/frontier-harness-eval).
DeepSWE’s 9 tasks are skipped (hidden verifiers).

Published board is **Kimi K3**. This folder also has **graff on grok-4.6**, **exo on grok-4.6**, and **graff on kimi-k3** (Moonshot metered).

| run | pass | list$ | notes |
|---|---|---|---|
| graff grok-4.6 first | 14/21 | $5.05 | SuperGrok OAuth, no eval append |
| graff grok-4.6 now | 20/21 | see `results.maxima.json` | eval-only `BENCH_APPEND`, not `prompt_text.zig` |
| graff kimi-k3 | 17/21 | $3.65 | Moonshot `$3 / $0.30 cached / $15` per 1M |
| exo grok-4.6 | 9/21 | n/a | no token events; 5 DNS flakes |

`tb21-graff-grok46.png` is the chart. Keys stay in the environment — nothing here is a credential.
