# Local harness latency measurements

Run this opt-in probe against a built graff binary:

```sh
python3 scripts/bench-harness-latency.py --out /tmp/graff-latency.json
python3 scripts/bench-harness-latency.py --tool-steps 1 --out /tmp/graff-tool-latency.json
```

It starts an immediate streaming model on loopback port 1234, uses a temporary
home and workspace, and runs three independent 100-turn sessions by default.
The port must be free; an existing server is never reused or terminated. There
are no paid inference calls. Provider credentials and custom configuration are
not inherited. Every request has a synthetic user payload (4096 bytes by
default), a tiny fixed response, and optionally one to three real local
`read_file` steps. Temporary sessions are removed on exit.

Use `--graff` for a particular binary, `--repeats 10` for more samples,
`--turns 200` for longer history, and `--payload-bytes 16384` for larger requests.
Use `--payload-kind code` to exercise quoted strings, backslashes, and newlines
instead of plain ASCII. Compare the same payload kind between binaries.
The local context limit is raised and usage is fixed to keep this a growing
history experiment; this does **not** evaluate realistic compaction behavior.
Extra model requests, failed tools, unexpected responses, crashes, and timeouts
fail the run rather than becoming deceptively fast samples.

## Boundaries

| Measurement | What it includes |
|---|---|
| `prompt_to_request_ms` | Writing a JSON user message until the loopback server receives request headers. First turn includes process startup; later turns include any pending prior-turn finalization. |
| `response_to_turn_ms` | Server beginning its response write until the client observes the JSON `turn` event. Includes local delivery, decoding, and event-reader scheduling. |
| `prompt_to_turn_ms` | Entire JSON prompt-to-turn interval, including fixture work and local transport. |
| `tool_roundtrip_ms` | Tool response beginning at the fixture through arrival of the following model request, including tool execution and next-request preparation. |
| `shutdown_ms` | Last observed turn through process exit, including final save/drain. |

Graff emits its JSON turn event before the normal end-of-turn autosave. The
probe immediately sends the next prompt, making delayed readiness visible in
the next `prompt_to_request_ms`. A quick turn event alone is not proof that
all foreground work has finished. These are external protocol boundaries,
not exact internal spans or terminal paint timings.

The JSON output contains raw timing samples, message counts, request sizes,
binary SHA-256, platform, and per-history-position median/p95/max. It contains
no prompts, request bodies, credentials, transcripts, or local binary paths.
With three repeats, p95 is effectively the maximum: collect more repetitions
before treating it as a stable tail estimate.

## Comparing candidates

Keep immutable baseline and candidate binaries built with the same optimization
mode and run the same command against each. Alternate their order over multiple
rounds on an otherwise idle machine. Compare identical history positions,
payload sizes, request counts, and tool-step settings. Compare both latency and
request sizes; faster runs that silently lose history are not improvements.
The runner rejects a binary modified during measurement.

Keep outputs local. Do not paste raw measurements or environment details into
public tracker entries. This is deliberately separate from deterministic tier 1
checks: host wall-clock thresholds need calibration. Tier 2 remains the place
to assert behavioral correctness, including recovery and compaction.

## What transfers from fx

The [v0.0.10 release](https://github.com/vercel-labs/fx/releases/tag/v0.0.10)
attributes speed gains to two paths:

- [Background usage publication](https://github.com/vercel-labs/fx/pull/858)
  removes synchronous full-ledger processing from turn completion while retaining
  a synchronous checkpoint and final shutdown flush. Graff's pricing tally is
  in memory, and interactive session disk writes are already queued. Its session
  fingerprinting, transcript recording, and snapshot serialization still execute
  on the caller; these are candidates for profiling, not a proven bottleneck.
- [Credential freshness](https://github.com/vercel-labs/fx/pull/861) skips repeated
  OS secret-store reads for a short freshness window. Graff caches stored API
  keys, but login credentials have a separate pre-request refresh path. In
  particular, its login-file reread deliberately picks up an external login on
  the next request. A time-based cache changes that contract; measure the file
  path separately and retain root/child recovery and account checks before
  considering such a change. This loopback benchmark uses an environment key
  and therefore does not measure login-file or Keychain performance.

fx also runs [startup budgets and runtime/terminal benchmarks](https://github.com/vercel-labs/fx/blob/v0.0.10/.github/workflows/bench.yml).
The transferable practice is controlled fixtures, raw samples, explicit
measurement boundaries, and correctness gates. Their published speedup ratios
are workload-specific and are not predictions for graff.

Further coverage would need separate fixtures for resumed histories and large
session directories, login-file refresh, ACP/TUI presentation, cancellation,
and injected persistence failures. The current probe covers growing live JSON
sessions and optional tool loops; it does not establish those other contracts.

## Adopted optimization

Profiling the growing-history fixture identified repeated serialization into a
discard writer for context estimation. `context_tokens.serializedLen` now counts
JSON containers and escaped string lengths directly, retaining the standard
serializer where its formatting is needed. This preserves byte counts and
context policy while avoiding unnecessary formatting. See [ADR 0115](adr/0115-context-estimates-count-json-bytes.md).
Compare both payload kinds and the tool-loop fixture when changing this path.
