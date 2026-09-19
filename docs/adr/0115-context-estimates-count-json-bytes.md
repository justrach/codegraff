# 0115. Context estimates count exact JSON bytes without formatting history

Status: accepted 2026-09-15

## Context

Context occupancy is computed repeatedly around requests and response handling.
The previous counter ran the complete JSON serializer into a discard writer.
Profiling found repeated formatting work, and paired ReleaseSafe loopback
benchmarks showed that avoiding it reduces overhead as history grows.

## Decision

Count dynamic JSON containers and encoded string lengths directly. Skip ordinary
string bytes in vector-sized blocks; count JSON escapes exactly. Use the standard
serializer for numeric formatting, invalid UTF-8 values, and generic Zig types.
Object keys retain the serializer's distinct key-encoding behavior.

Read the current tree on every call. Do not cache by history length or pointers:
compaction and tool-result repair can change existing values in place. Preserve
the existing image adjustment, rounding, and hidden-token accounting. This is
an implementation optimization, not a change in context or compaction policy.

## Consequences

The counter must match the toolchain's default JSON serialization. Differential
tests in `src/context_tokens.zig` cover escapes, Unicode, invalid bytes, nested
containers, numeric edge cases, and mutations. Keep these tests when updating
Zig. The opt-in `scripts/bench-harness-latency.py` compares identical text and
code-shaped workloads; raw timing evidence stays local. Host timings are not a
deterministic tier 1 gate.
