import { createWorkerAgent, type WorkerAgent, type WorkerTool } from "../../../sdk/ts/worker.ts";
import { createOtlpExporter, type SpanObserver } from "../../../sdk/ts/otel.ts";
import module from "../../../zig-out/bin/graff-worker.wasm?module";

type Env = { MODE?: string; MODEL_ENDPOINT?: string; MODEL_NAME?: string; MODEL_TOKEN?: string; INGRESS_TOKEN?: string };
function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
async function promptBody(request: Request): Promise<string> {
  if (!request.body) throw new Error("Missing prompt");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > 60 * 1024) { await reader.cancel(); throw new Error("Prompt too large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const real = env.MODE === "real";
    // Authenticate BEFORE instantiating an agent, reading a body, or spending.
    if (real && (!env.INGRESS_TOKEN || request.headers.get("authorization") !== `Bearer ${env.INGRESS_TOKEN}`)) {
      return new Response("Unauthorized", { status: 401 });
    }
    if (real && (!env.MODEL_ENDPOINT || !env.MODEL_NAME || !env.MODEL_TOKEN)) {
      return new Response("Model bindings are not configured", { status: 503 });
    }
    if (real && request.method !== "POST") return new Response("Use POST with a UTF-8 prompt", { status: 405 });
    const query = new URL(request.url).searchParams;
    const scenario = real ? "normal" : query.get("scenario") ?? "normal";
    if (!["normal", "unknown", "malformed", "bad-json", "cancel", "oversize"].includes(scenario)) {
      return new Response("Unknown scenario", { status: 400 });
    }
    // Synthetic collector only: fixture telemetry never leaves this isolate.
    const observation = real ? null : query.get("observe");
    const payloads: unknown[] = [];
    const spans: unknown[] = [];
    const exporter = observation ? createOtlpExporter({
      url: "https://collector.invalid/v1/traces", apiKey: "synthetic-collector-token",
      fetch: async (_url, init) => {
        payloads.push(JSON.parse(String(init?.body)));
        return new Response(null, { status: observation === "collector-fail" ? 503 : 200 });
      },
    }) : undefined;
    const observe: SpanObserver | undefined = exporter ? span => {
      spans.push(span);
      exporter.observe(span);
      if (observation === "throw") throw new Error("synthetic-observer-error");
      if (observation === "reject") return Promise.reject(new Error("synthetic-observer-error"));
      if (observation === "pending") return new Promise<void>(() => {});
    } : undefined;
    let concurrentRejected = false;
    let poisonedRejected = false;
    const telemetry = async () => {
      if (!exporter) return undefined;
      await exporter.flush();
      return { payloads, spans, dropped: exporter.dropped, concurrentRejected, poisonedRejected };
    };
    const controller = new AbortController();
    const abort = () => controller.abort();
    request.signal.addEventListener("abort", abort, { once: true });
    if (request.signal.aborted) abort();
    const events: string[] = [];
    let modelCalls = 0;
    let executed = 0;
    let toolAborted = false;
    const tool: WorkerTool = {
      name: "lookup", description: "Look up a public example value by key.",
      parameters: { type: "object", properties: { key: { type: "string" } }, required: ["key"], additionalProperties: false },
      validate: input => !!input && typeof input === "object" && !Array.isArray(input) &&
        Object.keys(input).length === 1 && typeof (input as { key?: unknown }).key === "string",
      async execute(input, { signal }) {
        executed++;
        events.push("tool");
        if (scenario === "cancel") {
          await new Promise<void>((_resolve, reject) => {
            signal.addEventListener("abort", () => { toolAborted = true; reject(new Error("Cancelled")); }, { once: true });
            setTimeout(abort, 10);
          });
        }
        await new Promise(resolve => setTimeout(resolve, 1));
        check(!signal.aborted, "Tool was aborted");
        return `value:${(input as { key: string }).key}`;
      },
    };
    const mockFetch: typeof fetch = async (_url, init) => {
      modelCalls++;
      events.push("model");
      check(init?.signal && !init.signal.aborted, "Missing model signal");
      const body = JSON.parse(String(init.body));
      check(body.model === "mock-model" && body.stream === false, "Wrong chat request");
      check(body.messages.some((m: { role: string }) => m.role === "user"), "Missing user prompt");
      if (scenario === "oversize") {
        // No Content-Length: the SDK must bound the actual stream.
        return new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(1024 * 1024 + 1)); c.close(); } }));
      }
      check(modelCalls <= 2, "Unexpected extra model call");
      if (modelCalls === 1) {
        check(body.tools?.some((t: { function?: { name: string } }) => t.function?.name === "lookup"), "Missing tool schema");
        await new Promise(resolve => setTimeout(resolve, 1));
        return Response.json({ choices: [{ message: { role: "assistant", content: null, tool_calls: [{
          id: "lookup_1", type: "function", function: {
            name: scenario === "unknown" ? "not_registered" : "lookup",
            arguments: scenario === "bad-json" ? "{" : JSON.stringify({ key: scenario === "malformed" ? 42 : "alpha" }),
          },
        }] }, finish_reason: "tool_calls" }] });
      }
      const result = body.messages.findLast((m: { role: string }) => m.role === "tool");
      check(result?.tool_call_id === "lookup_1", "Missing matching tool result");
      const invalid = ["unknown", "malformed", "bad-json"].includes(scenario);
      check(invalid ? executed === 0 && typeof result.content === "string" && result.content.length > 0
        : executed === 1 && result.content.includes("value:alpha"), "Host tool result was not fed to model");
      return Response.json({ choices: [{ message: { role: "assistant", content: invalid ? "Tool rejected safely" : "Found value:alpha" }, finish_reason: "stop" }] });
    };
    let agent: WorkerAgent | undefined;
    try {
      // A fresh instance for every request; no credentials are sent into Wasm.
      agent = await createWorkerAgent(module, {
        model: real ? env.MODEL_NAME! : "mock-model",
        endpoint: real ? env.MODEL_ENDPOINT! : "https://mock.invalid/v1/chat/completions",
        token: real ? env.MODEL_TOKEN : "synthetic-model-token",
        fetch: real ? fetch : mockFetch,
        instructions: "Use lookup when a value is requested. Do not invent values.",
        tools: [tool], maxSteps: 4, observe,
      });
      const pending = agent.prompt(real ? await promptBody(request) : "Look up alpha", { signal: controller.signal });
      if (!real && query.get("probe") === "concurrent") {
        try { await agent.prompt("synthetic-concurrent-prompt"); }
        catch (error) { concurrentRejected = error instanceof Error && error.message === "Agent prompt is already running"; }
        check(concurrentRejected, "Concurrent prompt was not rejected");
      }
      const result = await pending;
      return Response.json({ ok: true, ...result, observed: real ? undefined : { modelCalls, executed, events },
        telemetry: await telemetry() });
    } catch (error) {
      if (!real && agent && query.get("probe") === "poison") {
        try { await agent.prompt("synthetic-poisoned-prompt"); }
        catch { poisonedRejected = true; }
      }
      if (!real && scenario === "cancel" && controller.signal.aborted && toolAborted && error instanceof DOMException && error.name === "AbortError") {
        return Response.json({ ok: true, cancelled: true, toolAborted, observed: { modelCalls, executed, events },
          telemetry: await telemetry() });
      }
      // Engine/host details and credentials do not belong in ingress responses.
      return Response.json({ ok: false, error: "Agent request failed", observed: real ? undefined : { modelCalls, executed, events },
        telemetry: await telemetry() }, { status: 500 });
    } finally { request.signal.removeEventListener("abort", abort); }
  },
};
