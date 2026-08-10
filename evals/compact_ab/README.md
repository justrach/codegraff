# Compaction A/B: server-side vs client-side vs none

Pre-ship benchmark behind the `#compact-ab` telemetry experiment
(`src/agent_server_compact.zig`). Question: at a forced-low compaction
threshold (~16.3k tokens, `GRAFF_COMPACT_PCT=6` on the 272k window), which
compaction strategy preserves coding-task recall best, and at what cost?

## Task

`gen_compact_bench.py` writes a frozen synthetic Zig codebase
(`alpha…foxtrot.zig`, ~500 lines each, 12 planted `audit anchor` constants)
plus a one-line audit prompt: read all six files in full, then write
`answer.md` with 10 of the constants. Facts sit mid-file, and questions span
all six files, so a wrong answer means compaction destroyed early-file recall.
`GRAFF_TOOL_HANDLE_BYTES=262144` keeps full file contents in history (defeats
the #440 spill) so context actually crosses the threshold; `--yolo` because
scripted stdin sessions cannot approve writes (#unattended-gate).

## Arms

| arm | env |
|---|---|
| server | `GRAFF_SERVER_COMPACT=1 GRAFF_COMPACT_PCT=6` |
| client | `GRAFF_SERVER_COMPACT=0 GRAFF_COMPACT_PCT=6` |
| none | `GRAFF_SERVER_COMPACT=0 GRAFF_COMPACT_PCT=100` |

`run_compact_bench.sh wave N` runs one trial per arm in parallel; `score_compact_bench.py`
grades `answer.md` against `questions.json` and counts compaction notices.

## Results (gpt-5.6-sol, 2 trials/arm, 2026-08-10)

| run | score | compactions | wall | API calls | ctx tokens processed |
|---|---|---|---|---|---|
| none1 | 10/10 | 0 | 60s | 16 | 638k |
| none2 | 10/10 | 0 | 63s | 16 | 635k |
| server1 | 10/10 | 8 | 254s | 16 | 264k |
| server2 | 10/10 | 9 | 207s | 16 | 266k |
| client1 | 10/10 | 18 | 360s | 34 | 500k |
| client2 | 10/10 | 18 | 341s | 34 | 483k |

Read: recall tied at 10/10 everywhere at this scale. Forced to compact,
server-side dominated client-side on every cost axis (2.4× fewer tokens, no
extra round-trips — client burned 18 summary calls plus amnesia re-reads —
and ~40% less wall time). Not compacting beat both, as expected when the
workload fits the window: compaction is insurance, not a free lunch.

Known risk shape (observed in a pre-`--yolo` harness run): when forward
progress is blocked for an unrelated reason, aggressive server-side pruning
can erase "I already tried that" state and amplify a retry loop (25
compactions, no progress). Watch the `compact_ab` telemetry for arm=server
sessions with high prune_items counts and no turn completions.

## Telemetry (the real A/B)

In production each install is bucketed 50/50 by anonymous install id
(`armForId`). OTLP records: body=`experiment`, kind=`compact_ab`, detail ∈
`arm=server|arm=client` (once per process), `prune_items=N` (per server
prune), `summary_chars=N` (per client summary on the Responses wire).
`GRAFF_SERVER_COMPACT=0|1` forces an arm (and skips assignment).
