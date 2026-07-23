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
| `memory_session.py` | RSS-vs-turn slope plus session/scratch arena capacity for ONE persistent `--json` session (the #124 leak detector; `memory.py` is one-shot peak RSS and structurally blind to per-turn growth) | flat slope after warmup = no per-turn leak |
| `model_shape.py` | Correctness, quality-diversity, latency, tool/model calls, and routing for configurable Sol-root worker shapes | writes a local correctness-first paired report; no default promotion |

```sh
python3 benchmarks/cost.py
python3 benchmarks/memory.py
python3 benchmarks/latency.py 8
python3 benchmarks/memory_session.py 50   # N turns, one persistent session
python3 benchmarks/model_shape.py --graff zig-out/bin/graff --repetitions 1
```

`memory_session.py` drives and samples one turn at a time so the child remains
alive at every RSS sample. Set `GRAFF_BENCH_MODEL` to test a model other than
`deepseek-v4-pro`; the script enables `GRAFF_MEM_DEBUG` itself and prints both
arena capacities beside process RSS.

Tasks live in `tasks.py` (edit to test other work).

### Root/worker model shapes

`model_shape.py` creates disposable synthetic repositories and runs paired arms
with the same `gpt-5.6-sol` root. Its defaults remain:

- `all-sol`: both direct workers also use Sol;
- `sol-terra`: both direct workers use `gpt-5.6-terra`.

Every run must produce exactly two correctly routed child trajectory nodes.
Visible tests provide normal agent feedback, while held-back cases grade the
finished workspace afterward. The report selects correctness first and total
tool economy second. It also builds a small QD archive whose cells are declared
task niches: QD score sums each niche elite's normalized correctness, qualified
coverage counts fully correct/valid cells, and tool calls then wall time break
fitness ties. Promotion stays manual until at least 20 independent task pairs
are present. One repetition is therefore a smoke/effect-size check; seven
repetitions across the three core fixtures provide 21 pairs:

```sh
python3 benchmarks/model_shape.py \
  --graff zig-out/bin/graff \
  --repetitions 7 \
  --output-root /path/to/results
```

To compare Sol workers with explicitly consented Kimi K3 workers on the three
frontend niches (responsive layout, accessible interaction, and form state):

```sh
python3 benchmarks/model_shape.py \
  --graff zig-out/bin/graff \
  --task-set frontend \
  --worker codex:gpt-5.6-sol \
  --worker kimi:k3 \
  --output-root /path/to/results
```

The runner disables external telemetry, behavioral upload, fleet sharing,
Smolify, and optional companion tools. Only synthetic fixture content reaches
the selected provider accounts. Operational traces and the JSON report stay
inside the output directory.

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
  context, so the floor (~25 MB) is the headline, not a fixed number. Growth over
  a long session (independent of what is read) is a leak; `memory_session.py`
  measures exactly that slope per turn.
- `cost.py` omits graff on `gpt-5.5`: the codegraff gateway alias is not in graff's
  local price table, so graff reports `$0` for it (deepseek/glm price fine).
