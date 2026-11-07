// Experimental isolate-native host. Pass a statically imported WebAssembly.Module.
import type { SpanObserver, TraceSpan } from "./otel.ts";
export interface WorkerTool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
  /** Must reject malformed/untrusted inputs before execute is called. */
  validate(input: unknown): boolean;
  execute(input: unknown, context: { signal: AbortSignal }): string | Promise<string>;
}
export interface WorkerAgentOptions {
  model: string;
  instructions?: string;
  maxSteps?: number;
  tools?: readonly WorkerTool[];
  /** Full chat-completions URL; HTTPS except explicitly opted-in loopback tests. */
  endpoint: string;
  token?: string;
  fetch?: typeof fetch;
  allowLoopbackHttp?: boolean;
  /** Optional content-free lifecycle observer; never awaited by execution. */
  observe?: SpanObserver;
}
export interface WorkerResult { text: string; modelCalls: number; toolCalls: number }
export interface WorkerAgent {
  prompt(text: string, options?: { signal?: AbortSignal }): Promise<WorkerResult>;
  cancel(): void;
}
type Core = {
  memory: WebAssembly.Memory;
  graff_worker_in_ptr(): number;
  graff_worker_in_cap(): number;
  graff_worker_out_ptr(): number;
  graff_worker_out_len(): number;
  graff_worker_create(len: number): number;
  graff_worker_prompt(len: number): number;
  graff_worker_cancel(): void;
};
type HostCall = (kind: number, ptr: number, len: number, reply: number, cap: number) => Promise<number>;
type Jspi = {
  Suspending: new (fn: HostCall) => NonNullable<Parameters<typeof WebAssembly.instantiate>[1]>[string][string];
  promising(fn: Core["graff_worker_prompt"]): (len: number) => Promise<number>;
};
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });
const LIMIT = 1024 * 1024;
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const aborted = () => new DOMException("Agent cancelled", "AbortError");
function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(aborted());
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
    work.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}
async function responseBytes(response: Response, signal: AbortSignal): Promise<Uint8Array> {
  if (!response.body) throw new Error("Model response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const part = await abortable(reader.read(), signal);
      if (part.done) break;
      length += part.value.byteLength;
      if (length > LIMIT) throw new Error("Model response exceeds 1 MiB");
      chunks.push(part.value);
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

/** No native process, filesystem, dynamic compilation, or credential enters Wasm. */
export async function createWorkerAgent(module: WebAssembly.Module, options: WorkerAgentOptions): Promise<WorkerAgent> {
  const jspi = WebAssembly as unknown as Jspi;
  if (typeof jspi.Suspending !== "function" || typeof jspi.promising !== "function") {
    throw new Error("Worker runtime requires WebAssembly JSPI");
  }
  const endpoint = new URL(options.endpoint);
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname);
  if (endpoint.username || endpoint.password || endpoint.hash ||
      (endpoint.protocol !== "https:" && !(options.allowLoopbackHttp && loopback && endpoint.protocol === "http:"))) {
    throw new Error("Use an explicit HTTPS model endpoint (loopback HTTP requires opt-in)");
  }
  if (!options.model || (options.maxSteps !== undefined &&
      (!Number.isInteger(options.maxSteps) || options.maxSteps < 1 || options.maxSteps > 64))) {
    throw new Error("Model and maxSteps (1..64) are required to be valid");
  }
  const tools = new Map<string, WorkerTool>();
  for (const tool of options.tools ?? []) {
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(tool.name) || tools.has(tool.name) ||
        typeof tool.validate !== "function" || typeof tool.execute !== "function") throw new Error("Invalid or duplicate tool");
    tools.set(tool.name, tool);
  }
  let core: Core;
  let active: AbortController | undefined;
  let busy = false;
  const host: HostCall = async (kind, ptr, len, reply, cap) => {
    try {
      const signal = active?.signal;
      if (!signal || signal.aborted || len > LIMIT || cap > LIMIT) return -1;
      const raw = decoder.decode(new Uint8Array(core.memory.buffer, ptr, len));
      const request: unknown = JSON.parse(raw);
      let bytes: Uint8Array;
      if (kind === 1) {
        if (!object(request) || request.stream !== false) return -1;
        const headers = new Headers({ "content-type": "application/json" });
        if (options.token) headers.set("authorization", `Bearer ${options.token}`);
        const response = await abortable((options.fetch ?? fetch)(endpoint.href, {
          method: "POST", headers, body: raw, signal, redirect: "manual",
        }), signal);
        if (!response.ok) { void response.body?.cancel().catch(() => {}); return -1; }
        bytes = await responseBytes(response, signal);
      } else if (kind === 2) {
        let result = { text: "Unknown or malformed tool call", is_error: true };
        const tool = object(request) && typeof request.name === "string" ? tools.get(request.name) : undefined;
        if (tool && object(request) && typeof request.id === "string") {
          try {
            if (tool.validate(request.input)) {
              const text = await abortable(Promise.resolve().then(() => {
                if (signal.aborted) throw aborted();
                return tool.execute(request.input, { signal });
              }), signal);
              result = typeof text === "string" ? { text, is_error: false } : { text: "Tool must return text", is_error: true };
            }
          } catch { result = { text: "Tool execution failed", is_error: true }; }
        }
        bytes = encoder.encode(JSON.stringify(result));
        if (bytes.length > LIMIT || bytes.length > cap) {
          bytes = encoder.encode(JSON.stringify({ text: "Tool response exceeds limit", is_error: true }));
        }
      } else return -1;
      if (signal.aborted || bytes.length > cap || bytes.length > LIMIT) return -1;
      // Awaited work may grow Wasm memory: always reacquire the current buffer.
      new Uint8Array(core.memory.buffer, reply, bytes.length).set(bytes);
      return bytes.length;
    } catch { return -1; }
  };
  const instance = await WebAssembly.instantiate(module, { env: { graff_host_call: new jspi.Suspending(host) } });
  core = instance.exports as unknown as Core;
  if (!(core.memory instanceof WebAssembly.Memory) || ["graff_worker_in_ptr", "graff_worker_in_cap",
      "graff_worker_out_ptr", "graff_worker_out_len", "graff_worker_create", "graff_worker_prompt",
      "graff_worker_cancel"].some(name => typeof instance.exports[name] !== "function")) {
    throw new Error("Missing experimental worker ABI exports");
  }
  const write = (text: string) => {
    const bytes = encoder.encode(text);
    if (bytes.length > core.graff_worker_in_cap()) throw new Error("Agent input exceeds Wasm input capacity");
    new Uint8Array(core.memory.buffer, core.graff_worker_in_ptr(), bytes.length).set(bytes);
    return bytes.length;
  };
  const output = (status: number): unknown => {
    const length = core.graff_worker_out_len();
    if (length > LIMIT) throw new Error("Agent output exceeds limit");
    const result: unknown = JSON.parse(decoder.decode(new Uint8Array(core.memory.buffer, core.graff_worker_out_ptr(), length)));
    if (status !== 0 || (object(result) && "error" in result)) throw new Error("Worker engine failed");
    return result;
  };
  const status = core.graff_worker_create(write(JSON.stringify({
    model: options.model, instructions: options.instructions, maxSteps: options.maxSteps ?? 16,
    tools: [...tools.values()].map(tool => ({ type: "function", function: {
      name: tool.name, description: tool.description, parameters: tool.parameters,
    } })),
  })));
  if (status !== 0) throw new Error("Worker engine configuration failed");
  const prompt = jspi.promising(core.graff_worker_prompt);
  const cancel = () => { if (active && !active.signal.aborted) { active.abort(); core.graff_worker_cancel(); } };
  return {
    cancel,
    async prompt(text, { signal } = {}) {
      if (busy) throw new Error("Agent prompt is already running");
      if (signal?.aborted) throw aborted();
      busy = true;
      active = new AbortController();
      signal?.addEventListener("abort", cancel, { once: true });
      let span: TraceSpan | undefined;
      try {
        if (options.observe) {
          try {
            const hex = (bytes: number) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)),
              value => value.toString(16).padStart(2, "0")).join("");
            span = { traceId: hex(16), spanId: hex(8), name: "graff.turn",
              startTimeUnixNano: (BigInt(Date.now()) * 1_000_000n).toString(), endTimeUnixNano: "0",
              status: { code: 2 } };
          } catch { /* Observability cannot prevent a turn. */ }
        }
        const code = await prompt(write(text));
        if (active.signal.aborted) throw aborted();
        const result = output(code);
        if (!object(result) || typeof result.text !== "string" || !Number.isInteger(result.modelCalls) ||
            !Number.isInteger(result.toolCalls)) throw new Error("Malformed engine output");
        if (span) {
          span.status = { code: 1 };
          span.attributes = { "graff.api_calls": result.modelCalls as number };
        }
        return result as unknown as WorkerResult;
      } finally {
        signal?.removeEventListener("abort", cancel);
        active = undefined;
        busy = false;
        if (span) {
          try {
            const end = BigInt(Date.now()) * 1_000_000n;
            span.endTimeUnixNano = (end < BigInt(span.startTimeUnixNano) ? BigInt(span.startTimeUnixNano) : end).toString();
            // Consume rejected observers without awaiting slow or stuck observers.
            void Promise.resolve(options.observe?.(span)).catch(() => {});
          } catch { /* No errors or execution content enter telemetry. */ }
        }
      }
    },
  };
}
