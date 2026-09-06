# 0075. Separate ACP presentation adapters and measure desktop workloads

Status: accepted

## Decision

The TUI backend value types live separately from the mutable callback registry.
ACP transcript decoding lives separately from session lifecycle. In-process text
chunks use the same normalized decoder operation as wire chunks, avoiding JSON
allocation and parsing when both endpoints already share a process. Tool events
retain their wire path. Parity tests cover reasoning visibility and Unicode.
Coding and session policy remain in the harness; desktop rendering stays a client.

Desktop profiling extends the bounded, opt-in measurement report (ADR 0072).
Paint timings cover document startup; interaction latency, streaming, heap,
process-tree resources and event-loop delay cover ongoing use. Unavailable
measurements are null. GPU feature status is allowlisted; GPU-process CPU/RSS
must never be presented as device utilization or dedicated video memory.
Chromium chooses its supported hardware backend; no forced driver overrides or
custom shader pipeline without a measured workload that benefits.

## Consequences

Synthetic GUI workloads can run without credentials or a model and generate
public-safe demonstration images. Their measurements are lab evidence, not
field percentiles or proof of faster real-model turns. Performance reports carry
no transcript, device identifier or raw profiling trace. Screenshots are separate,
explicit test artifacts. New optimizations require comparable before/after runs.
