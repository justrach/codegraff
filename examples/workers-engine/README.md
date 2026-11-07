# Graff inside a Worker

Experimental Worker-native execution, not a proxy to `graff serve` and not the
older echo-only ACP embedding. Zig owns the conversation and runs the same chat
step used by Graff's native REPL and ACP engine. JavaScript supplies asynchronous
model HTTP and explicitly registered tools through WebAssembly JSPI.

## Run locally

Requires Zig 0.17.0 and Node 22 or later. From the repository root:

```sh
zig build wasm-worker
cd examples/workers-engine
npm ci
npm run typecheck
npm test
npm run dev
```

Open the local URL printed by `cf dev`. The default mode is a credential-free
synthetic integration: model tool call → asynchronous `lookup` → model receives
the result → final answer. No real model endpoint is called. The runtime test
starts and stops its own cf/workerd server.

```sh
npx cf deploy --dry-run
```

This builds and checks the deployable bundle without uploading it. Local tests
and a dry run do not establish hosted production behavior. `cf` comes from
Cloudflare's `cloudflare/cf` project; its Vite plugin uses the Workers SDK's
workerd runtime.

## Real model mode

Set `MODE` to `real` and configure `MODEL_ENDPOINT` (a full HTTPS chat-completions
URL) and `MODEL_NAME` in `cloudflare.config.ts`. Supply `MODEL_TOKEN` and
`INGRESS_TOKEN` as Cloudflare secrets; never put their values in source. Deploy
with `npx cf deploy` after configuring the account and reviewing the bindings.

Send `POST` with a UTF-8 prompt body and `Authorization: Bearer <INGRESS_TOKEN>`.
Authentication is checked before agent creation or model spending. Keep that
credential on your backend, not in public browser code. The example is a small
integration surface, not a production multi-tenant gateway.

Credentials stay in the JS HTTP host and are never written into Wasm. The model
endpoint is configured by the host, never by the incoming request or model.
Tools are host-registered, must explicitly validate inputs, and receive an
`AbortSignal`. There is no native shell or arbitrary filesystem access.

## SDK boundary

`createWorkerAgent()` lives in `@codegraff/sdk/worker`; the example imports its
source to exercise this checkout. The module is supplied separately by the host:

```ts
import { createWorkerAgent } from "@codegraff/sdk/worker";
import core from "./graff-worker.wasm?module";

const agent = await createWorkerAgent(core, {
  endpoint: env.MODEL_ENDPOINT,
  token: env.MODEL_TOKEN,
  model: env.MODEL_NAME,
  tools: [],
});
const result = await agent.prompt("Hello", { signal: request.signal });
```

For optional metadata-only tracing, pass `observe: exporter.observe` from the
same `createOtlpExporter` in `@codegraff/sdk/otel` used by the managed relay, then
explicitly `await exporter.flush()`. Worker turns emit only random IDs, timing,
status and the numeric `graff.api_calls` count; no prompt, tool, error or model
content. Observer failures (or an observer that never settles) cannot change
execution. The runtime fixture exercises this with an in-isolate synthetic
collector; it sends no telemetry to a network collector.

Build `graff-worker.wasm` using `zig build wasm-worker` and bundle it at build
time. Runtime compilation of fetched Wasm bytes is not supported by ordinary
Workers. Do not import the Node-only ACP embed loader here. Instantiate a fresh
agent per request, as this example does, or serialize access to one agent within
a session owner. Overlapping prompts on one instance are refused. A failed or
cancelled turn poisons that session: create a new agent rather than replaying an
uncertain tool effect.

## First-milestone limits

- Chat Completions JSON only (`stream: false`); no Responses, Messages or
  Interactions transport yet.
- The native and Worker paths share `agent_chat_step.zig`: assistant history,
  tool-call argument validation, result replay, and tool/continue/final decisions.
  Native checkpointing and provider-specific repair stay in the native adapter.
- Bounded model steps, tool batches, input/output buffers and session memory.
  Undeclared and malformed calls cannot execute; tool failures return to the
  model as tool errors. Truncated output and exhausted limits fail explicitly.
- Cancellation reaches model fetch and host tools. Tools must honor their signal;
  aborting a request cannot undo an external effect already performed.
- No durable sessions, R2 checkpoints, compaction, goals, peer mail, delegation,
  native shell/git/compiler tools, or full CLI feature parity. Storage and an
  external execution sandbox are subsequent milestones, not implicit fallbacks.

The existing `wasm-core` target and `@codegraff/sdk/embed` remain a separate,
echo-only ACP protocol surface. This Worker ABI does not turn that stub into the
full native `Agent`.
