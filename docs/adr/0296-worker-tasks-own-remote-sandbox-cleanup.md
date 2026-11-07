# 0296. Worker tasks own remote sandbox cleanup

Status: experimental

## Context

A Durable Object can own the Worker-native agent's task state and await model
and tool calls, but it cannot spawn a Linux shell. Existing Codegraff cloud VMs
already provide that capability. The local MCP `run_task` endpoint is a distinct
service and can deny execution; it is not evidence about the hosted sandbox API.

## Decision

Keep orchestration and the shared Zig/Wasm chat step in the Worker. Register a
bounded host tool backed by Codegraff's public sandbox HTTP API. The DO owns one
disposable VM per task, records its ID before work, and schedules backup cleanup.
Use finally-based deletion with an independent deadline, an alarm for interrupted
requests, and a bounded lease. Do not retry create/exec implicitly: uncertain
effects are not safe to replay. Never inject the gateway credential into Wasm,
VM commands, or the VM environment. Refuse redirects rather than forwarding auth.

## Consequences

The opt-in `examples/workers-sandbox/live.test.mjs` exercises a real model and
VM and independently checks a synthetic code repair and resource cleanup. A
model's success claim alone does not pass. Local tests run workerd with an actual
DO, but are not proof of a hosted deployment or an adversarial isolation audit.
DO storage currently owns cleanup only, not a resumable model conversation.
Aborting HTTP stops waiting; VM deletion is the execution boundary. Future
long-running jobs need explicit job handles and recovery, not longer blind waits.
