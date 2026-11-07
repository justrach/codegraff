# 0295. Worker-native turns share the native chat step

Status: experimental

## Context

Workers can instantiate bundled Zig WebAssembly and suspend asynchronous host
imports through JSPI. A local workerd experiment with fx completed a model/tool
cycle. Graff's existing same-process surface is only an echo ACP core (0038);
its native Agent also owns process, filesystem, HTTP and threading dependencies.
Forwarding prompts to a native server would not be a Worker-native port, and a
second JavaScript agent loop would drift from Graff's engine.

## Decision

Add an explicitly experimental `wasm-worker` target and `@codegraff/sdk/worker`
host. Extract `agent_chat_step.zig` from the existing native step: REPL, ACP and
Worker hosts share assistant history, executable-call parsing, tool-result
replay and the continue/final decision. Native provider repair, checkpointing,
events and completion hooks stay in a native adapter. Do not replace the full
native turn policy with the experimental host's smaller policy.

The JS host supplies bounded model HTTP and registered tools through a suspending
import. Credentials remain outside Wasm. The Wasm module is statically bundled;
mutable instances belong to one request/session, not concurrent requests. Both
sides enforce budgets and reject unregistered or malformed tool execution. A
failed turn cannot implicitly replay uncertain effects.

## Consequences

The first slice supports nonstreaming Chat Completions and host tools, verified
by the real workerd cycle in `examples/workers-engine/runtime.test.mjs`. It does
not provide native shell tools, durable sessions, compaction, goals or full CLI
parity. Worker storage and an external shell sandbox are later capabilities,
not a reason to proxy the agent loop or silently run a different engine. Local
runtime proof and `cf deploy --dry-run` are not hosted deployment proof.
