# Benchmarks

Reproducible head-to-head of **graff** vs **Claude Code** vs **Codex**, behind the
numbers in the main README's [How it compares](../README.md#how-it-compares).

These are small, honest benchmarks (a few read-only code questions on one
machine), not a leaderboard. Run them yourself. Your numbers will vary with the
task, the model, and the network.

## Prerequisites

- `graff`, `claude`, and `codex` on your PATH, each authenticated.
- For `latency.py`, graff must be logged into Codex (`graff login codex`) so that
  `graff --model codex` hits the same ChatGPT endpoint as `codex exec` (no gateway).
- macOS for `memory.py` (it uses BSD `/usr/bin/time -l`).
- Python 3.

## What each script measures

| Script | Measures | Result we got |
| --- | --- | --- |
| `cost.py` | USD per task (each tool's own usage, [gateway prices](https://codegraff.com/docs/models)) | graff/deepseek-v4-pro **$0.022** vs Claude Code/Opus-4.8 **$0.51** vs Codex/gpt-5.5 **$0.42** |
| `memory.py` | Peak RSS + CPU (`/usr/bin/time -l`) | graff **~25 MB** floor vs Node **~410 MB** vs Rust **~206 MB** |
| `latency.py` | One-shot turn latency, same gpt-5.5 endpoint, concurrent pairs | graff **4.4 s** vs codex **8.9 s** (one-shot only) |

```sh
python3 benchmarks/cost.py
python3 benchmarks/memory.py
python3 benchmarks/latency.py 8
```

Tasks live in `tasks.py` (edit to test other work).

## Honest caveats (please read)

- **Cost is model freedom, not token savings.** On the *same* model, graff and
  Codex use comparable tokens (graff is leaner on single-tool lookups, heavier on
  multi-tool tasks because it makes more tool-calling rounds, each re-sending
  cached context). graff is cheaper because it can run a cheap capable model where
  Claude Code is Claude-only and Codex is GPT-only.
- **Speed is a one-shot win.** `latency.py` measures cold-start `-p` / `exec`
  invocations, where graff's tiny Zig startup beats Codex's heavier per-call
  launch. In a long interactive session this amortizes and turns are model-bound.
- **Memory is task-dependent.** graff's RSS grows with how much code it reads into
  context, so the floor (~25 MB) is the headline, not a fixed number.
- `cost.py` omits graff on `gpt-5.5`: the codegraff gateway alias is not in graff's
  local price table, so graff reports `$0` for it (deepseek/glm price fine).
