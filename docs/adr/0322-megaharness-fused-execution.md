# 0322. Megaharness: GPU-Megakernel-Inspired Fused Agent Execution

Date: 2026-11-09
Status: Accepted

## Context

In GPU inference (Stanford Hazy Research's *ThunderKittens* "No-Bubbles" Megakernel and CMU's *Mirage Persistent Kernel / MPK*), traditional frameworks launch one kernel per operator (`RMSNorm -> HBM -> Attention -> HBM -> MLP -> HBM`), paying host-launch bubbles between every operator and round-tripping intermediate activations through high-latency off-chip HBM. A GPU megakernel fuses the operator graph into a persistent device-resident execution loop with:

1. **Zero-bubble stream overlapping**: launching independent tile loads while the instruction stream is still arriving.
2. **Multi-wave dependency DAG scheduling (MPK wavefronts)**: partitioning instructions into dataflow waves so that once wave $W$ resolves a register binding, independent operations in wave $W+1$ that consume that register fan out concurrently instead of dropping to serial execution after the first barrier.
3. **On-chip SRAM register residency vs. HBM round-trips**: keeping intermediate values in fast local registers across fused operations and only writing the final output back to HBM.

Agent harnesses face the exact same structural bottleneck: one-tool-per-turn execution round-trips every intermediate file read or search result through the remote LLM context window ("HBM"), paying network/TTFT "launch bubbles" and context token amplification on every step.

Prior to this ADR, `src/rlm.zig` overlapped only the *leading* literal statements (`rlm_order.leading`) up to the first non-literal barrier, and executed all remaining statements in the script strictly serially even when later waves of `read_file`/`codedb`/`llm_query`/`sleep_ms` calls only depended on bindings (`binds`) already resolved by an earlier statement.

## Decision

1. **Multi-Wave Dependency DAG Scheduling (`src/megaharness.zig`, `src/rlm.zig`)**:
   - `megaharness.collectWave(arena, stmts, binds)` inspects the remaining statements at any wavefront boundary against the currently resolved `binds` register file.
   - Consecutive safe calls (`read_file`, `codedb`, `llm_query`, `sleep_ms`, or `print(...)` of safe calls) whose argument identifiers are already bound in `binds` — and that have no intra-wave Read-After-Write (RAW) hazard — are grouped into a concurrent wavefront and launched together via `speculate` / `launchHost`.
   - Pre-wave `claimed` cache entries are cleared at wave boundaries so post-mutation waves always observe fresh filesystem state while still overlapping within their own wave.
2. **SRAM Register Locality & Fusion Telemetry (`/megaharness`, `/kernel`)**:
   - `megaharness.Stats` records `scripts_fused`, `ops_executed`, `waves_launched`, `parallel_ops_fused`, `speculative_stream_hits`, `llm_round_trips_saved`, `sram_register_bytes` (bytes bound in local `rlm` registers), and `hbm_context_bytes_emitted` (bytes emitted by `print()` to the model context window).
   - `/megaharness [json|reset]` (alias `/kernel`) surfaces these metrics in the line REPL and ACP.

## Consequences

- Multi-step `rlm` scripts that compute or project intermediate bindings (`p = project(...)` or literal assignments) and then fan out across multiple reads or `codedb` queries now execute those post-barrier waves concurrently.
- Operators and evaluations can inspect exact LLM round-trips saved, zero-bubble SSE speculative hits, and SRAM-vs-HBM byte locality via `/megaharness` (`--json`).
