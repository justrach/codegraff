# Recursive Flint on a local MLX server

Measured 2026-10-22. Recursive Flint (39.8B total parameters, about 2.5B active per token) ran the same 21 tasks as the gateway write-ups, 2 runs of each, through graff's `mlx` provider. The weights are the MLX INT4 checkpoint (`flint-int4`), served on one Apple M4 Pro with 48 GB by Recursive's `rec` 0.1.0, an OpenAI-compatible server at `127.0.0.1:8080`. Every call was local, so the runs cost nothing.

| Arm | What ran |
| --- | --- |
| graff | This branch's build as a scripted `graff repl` on the `graff-mlx-repl` arm (`--model mlx/flint`), at the default effort. |

| | Pass | Wall per task | Input read from cache | Output tokens per task | Model calls per task |
| --- | ---: | ---: | ---: | ---: | ---: |
| graff + Flint INT4 (local) | 39/42 | 80.4s | 84% | 3,439 | 6.6 |

By suite:

| Suite | Pass | Wall per task | Input read from cache | Output tokens per task |
| --- | ---: | ---: | ---: | ---: |
| core (11 coding tasks) | 22/22 | 16.8s | 80% | 619 |
| mcp (10 MCP tasks) | 17/20 | 150.4s | 86% | 6,541 |

All three misses are timeouts, not wrong answers: both runs of `linear-split` and one run of `linear-quiet` reached the 240 s task limit before writing their report. Flint reasons at length on the MCP tasks (5,000 to 11,000 output tokens per run), so the tasks that time out are the ones where that reasoning plus local decoding runs past the limit. The `linear-quiet` run that finished took 187 s. Every finished run passed its held-out check.

Against the hosted models in [mimo-v2.6](../mimo-v2.6/RESULTS.md), the pass rate matches MiMo v2.6 Pro with thinking off (39/42), and the core suite takes about as long as MiMo with thinking on (16.8s against 15.8s). The MCP tasks take longer because Flint writes more and decodes it locally.

## Prompt cache

`rec` keeps one prompt cache and reuses the longest prefix it shares with the next request. Inside a session, each request reused the whole previous prompt, so only the new tool output and reply were prefilled. graff sends each assistant turn's `reasoning_content` back in the history, which keeps the rendered prompt identical to what the server cached. Across runs, the shared system prompt hits the cache too: `exact-reply` took 11.5 s cold and 1.7 s warm. Because there is one cache, the suite ran one task at a time (`-j 1`); parallel sessions would evict each other's prefix.

## Throughput

Single streamed requests with no tools and a unique prefix (so nothing came from cache), 512 output tokens:

| Prompt | Prefill | Decode |
| --- | ---: | ---: |
| ~900 tokens | 660 to 790 tok/s | 117 to 123 tok/s |
| ~7,000 tokens | 480 to 600 tok/s | 105 to 109 tok/s |
| ~28,000 tokens | 500 to 545 tok/s | 80 tok/s |

In the suite's long MCP runs, where output dominates, decoding ran at about 63 to 96 tok/s with 20,000 to 50,000 tokens of context per request.

## Per task

Wall time is the mean of 2 runs; a task that failed in a run is marked with its pass count.

| Task | Suite | Wall | Output tokens | Model calls |
| --- | --- | ---: | ---: | ---: |
| [`csv-sum`](../../graff-evals/tasks/11-csv-sum.json) | core | 21.2s | 513 | 6.0 |
| [`dead-code`](../../graff-evals/tasks/12-dead-code.json) | core | 13.2s | 496 | 3.0 |
| [`exact-reply`](../../graff-evals/tasks/01-exact-reply.json) | core | 6.6s | 123 | 1.0 |
| [`file-ops`](../../graff-evals/tasks/03-file-ops.json) | core | 14.3s | 551 | 3.0 |
| [`fix-fib`](../../graff-evals/tasks/02-fix-fib.json) | core | 23.5s | 1,035 | 5.5 |
| [`git-ops`](../../graff-evals/tasks/08-git-ops.json) | core | 16.2s | 456 | 3.5 |
| [`json-transform`](../../graff-evals/tasks/04-json-transform.json) | core | 10.2s | 417 | 3.0 |
| [`recall-noise`](../../graff-evals/tasks/09-recall-noise.json) | core | 7.4s | 104 | 2.0 |
| [`refactor-rename`](../../graff-evals/tasks/06-refactor-rename.json) | core | 16.0s | 395 | 6.0 |
| [`regex-count`](../../graff-evals/tasks/05-regex-count.json) | core | 30.9s | 1,740 | 6.0 |
| [`write-tests`](../../graff-evals/tasks/07-write-tests.json) | core | 25.6s | 977 | 7.0 |
| [`linear-issues`](../../graff-evals/tasks/24-linear-issues.json) | mcp | 86.7s | 5,545 | 7.0 |
| [`linear-nohint`](../../graff-evals/tasks/30-linear-nohint.json) | mcp | 172.0s | 11,315 | 11.5 |
| [`linear-nohint-warm`](../../graff-evals/tasks/31-linear-nohint-warm.json) | mcp | 125.1s | 6,642 | 6.0 |
| [`linear-quiet`](../../graff-evals/tasks/28-linear-quiet.json) | mcp | 213.5s (1/2) | 5,338 | 5.0 |
| [`linear-quiet-warm`](../../graff-evals/tasks/29-linear-quiet-warm.json) | mcp | 134.0s | 8,904 | 7.0 |
| [`linear-reduce`](../../graff-evals/tasks/32-linear-reduce.json) | mcp | 97.2s | 5,691 | 12.0 |
| [`linear-reduce-warm`](../../graff-evals/tasks/33-linear-reduce-warm.json) | mcp | 93.9s | 5,941 | 8.0 |
| [`linear-sidecar`](../../graff-evals/tasks/26-linear-sidecar.json) | mcp | 211.0s | 9,802 | 18.5 |
| [`linear-split`](../../graff-evals/tasks/27-linear-split.json) | mcp | 240.1s (0/2) | timed out | timed out |
| [`linear-warm`](../../graff-evals/tasks/25-linear-warm.json) | mcp | 130.3s | 6,234 | 18.0 |

A timed-out run records no usage, so its output and calls count as 0 in the averages above.

## Reproduce

Install `rec` ([recursive-oss/rec](https://github.com/recursive-oss/rec)), then `rec pull` and `rec serve --port 8080`. With `MLX_API_KEY=$(rec auth token)` set, run `graff-evals/run.py --suite core,mcp --harness graff-mlx-repl --model flint --reps 2 -j 1` with `--output-root` outside any repository and `scripts/linear_fixture_mcp.py` copied next to it.
