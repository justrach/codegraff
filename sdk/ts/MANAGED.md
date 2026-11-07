# Managed sessions and opt-in traces

The experimental `@codegraff/sdk/managed` client uses the existing account remote-control relay. It runs the **same native Graff engine** on an explicitly selected registered device: all of that engine's configured providers remain available. It does not introduce another agent loop or provision a machine.

The client uses only fetch/Web APIs. It can run in Node, Bun or a Worker; **this relay transport** keeps the agent and tools on the device, not inside the Worker isolate. The separate experimental `@codegraff/sdk/worker` path hosts Graff's Zig/Wasm chat step inside the Worker, with `@codegraff/sdk/worker-sandbox` providing remote shell execution. That experiment is not a resumable conversation service: its sandbox example currently retains cleanup ownership, not conversation checkpoints. These are distinct execution transports, not two competing agent engines or interchangeable durability guarantees.

Use server-side secrets, never a public browser bundle. The account key must have the `remote` scope; a model-only API key cannot access devices or their sessions.

```ts
import { ManagedHarness } from "@codegraff/sdk/managed";
import { createOtlpExporter } from "@codegraff/sdk/otel";

// Set this to your managed relay's HTTPS origin.
const url = process.env.CODEGRAFF_MANAGED_URL!;
const apiKey = process.env.CODEGRAFF_API_KEY!;

// Optional: enable only when this origin has the SDK trace collector deployed.
const traces = createOtlpExporter({ url: `${url}/v1/traces`, apiKey });
const client = new ManagedHarness({ url, apiKey, observe: traces.observe });
const devices = await client.devices();
const device = devices.find(d => d.online);
if (!device) throw new Error("Register an execution device first");
const session = await client.session({
  deviceId: device.agent_id,
  session: "sdk-example",
  maxModelCalls: 2,
});

// Choose an application-stable id. A POST is not automatically retried.
const receipt = await session.submit("Reply with a short greeting; do not use tools", {
  messageId: "greeting-1",
});
// Persist receipt in YOUR application's durable store before watching.
// It includes no prompt or key. Keep a cursor alongside it.
let next = receipt.from;
try {
  for await (const event of session.watch(receipt, { from: next })) {
    // Commit the event/application effect and next cursor atomically when needed.
    if (event.type === "text") process.stdout.write(event.text);
    next = event.seq + 1;
  }
} finally {
  await traces.flush(); // Worker callers must await this or use ctx.waitUntil.
}
console.log({ traceId: receipt.traceId, droppedSpans: traces.dropped });
```

A replacement SDK process can call `client.attach(receipt.sessionId).watch(receipt, { from: next })`. Transient reads retry within a bound, event-window gaps request replay from the device tape, and reconnect never submits a second prompt. To inspect execution, call `session.status()`; to stop it, call `session.cancel()`. Stopping iteration or aborting `watch` detaches the viewer without stopping remote work. `session.close()` explicitly closes the execution session.

## Durability boundaries

- A successful submit acknowledges the relay's queued command, not a completed turn or a model-start receipt. A lost POST response is ambiguous. Inspect/reconnect rather than blindly resubmitting.
- Use one active writer/turn per session. Receipts do not fence concurrent writers or identify a per-command event range; the event tape is session-scoped.
- Event replay and completed conversation checkpoints live with the native execution device/workspace. Replacing the relay/client is not the same as losing the device or its disk. A dead device is not automatically migrated or a half-completed tool re-executed.
- Current message-id deduplication is bounded and in memory. It is **not crash-safe exactly-once delivery**; command dispatch also has failure windows. Do not automatically retry externally visible effects without application idempotency keys.
- Receipts and cursors are caller-owned. The SDK does not silently write prompts or application data into a cloud store. Replayed events may repeat application effects unless your cursor/effect commits are atomic.
- The relay may replace oversized events with stubs. The SDK fails explicitly instead of silently treating a truncated event as complete.

## Traces, not transcripts

Tracing is opt-in. The default turn span includes random trace/span IDs, timing, status and numeric usage/event/reconnect counts. Prompts, assistant text, reasoning, tool arguments/results, error bodies, model/provider/account/device/session labels and credentials are excluded. Keys travel only in the authorization header. Exports are bounded and time out; a collector failure does not fail the agent turn. `dropped` makes best-effort loss visible.

The managed collector accepts this **restricted SDK OTLP/HTTP JSON profile**, not arbitrary third-party spans. It reconstructs an allowlisted envelope and stores it privately per authenticated account. With that collector deployed, `GET /v1/traces/<traceId>` retrieves OTLP JSON and `DELETE /v1/traces/<traceId>` deletes it, using the same remote-scoped authorization header. Limits are 64 spans per request/trace and 128 recent traces per account; traces expire after seven idle days. There is no hosted trace UI in this change. A standard OTLP collector can also receive the SDK export by setting its HTTPS URL explicitly.

This is a local integration path until the managed collector is deployed; installing a Node package does not deploy a backend or grant a model-only key remote-control access.

For custom deployments, retention, exporters or durability requirements, email **rach@standardharness.com**.
