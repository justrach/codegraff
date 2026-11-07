/** Fetch-only client for an account's existing remote-control relay.
 * Execution/checkpoints remain on the registered device, not in this client.
 */
import type { Event } from "./remote.ts";
import type { SpanObserver, TraceSpan } from "./otel.ts";

export interface ManagedOptions {
  url: string;
  /** Requires the remote-control scope; never put a key in a browser bundle. */
  apiKey: string;
  fetch?: typeof fetch;
  observe?: SpanObserver;
  /** Network GET retries only. Prompt submission is NEVER automatically retried. */
  reconnectAttempts?: number;
}

export interface ManagedSessionInfo {
  session_id: string;
  agent_id: string;
  state: "idle" | "busy";
  last_seq: number;
  online: boolean;
}

/** Persist this receipt in your own durable storage; it contains no key/prompt.
 * `from` is inclusive. Advance it only after your application commits an event.
 */
export interface ManagedReceipt {
  sessionId: string;
  commandId: string;
  messageId: string;
  from: number;
  traceId: string;
  spanId: string;
  startedUnixNano: string;
}

export class ManagedRequestError extends Error {
  constructor(readonly status: number) {
    super(`Managed request failed (HTTP ${status}); no request was automatically retried`);
  }
}

const SESSION = /^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/;
const DEVICE = /^[a-f0-9]{16,32}$/;
const integer = (n: unknown): n is number => Number.isSafeInteger(n) && Number(n) >= 1;
const nano = () => (BigInt(Date.now()) * 1_000_000n).toString();
const hex = (bytes: number) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), x => x.toString(16).padStart(2, "0")).join("");

/** Managed relay client. Creating a session never provisions or bills a device. */
export class ManagedHarness {
  private readonly base: string;
  private readonly fetcher: typeof fetch;
  private readonly retries: number;

  constructor(private readonly options: ManagedOptions) {
    const url = new URL(options.url);
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    if ((url.protocol !== "https:" && !(local && url.protocol === "http:")) ||
        url.username || url.password || url.search || url.hash || url.pathname !== "/") {
      throw new Error("Managed URL must be an HTTPS origin (HTTP allowed on loopback only)");
    }
    if (!options.apiKey || /[\r\n]/.test(options.apiKey)) throw new Error("An API key is required");
    this.base = url.origin;
    // Native Worker fetch rejects a ManagedHarness instance as its receiver.
    this.fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
    this.retries = options.reconnectAttempts ?? 3;
    if (!Number.isInteger(this.retries) || this.retries < 0 || this.retries > 10) throw new Error("reconnectAttempts must be 0..10");
  }

  private async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
    const response = await this.fetcher(this.base + path, {
      // Workers supports manual redirects; reject non-2xx without forwarding keys.
      method, redirect: "manual", signal: signal ?? AbortSignal.timeout(35_000),
      headers: { Authorization: `Bearer ${this.options.apiKey}`, "content-type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new ManagedRequestError(response.status);
    }
    return await response.json() as T;
  }

  async devices(): Promise<{ agent_id: string; online: boolean }[]> {
    const result = await this.request<{ agents: { agent_id: string; online: boolean }[] }>("GET", "/v1/remote/agents");
    return result.agents;
  }

  async sessions(): Promise<ManagedSessionInfo[]> {
    return (await this.request<{ sessions: ManagedSessionInfo[] }>("GET", "/v1/remote/sessions")).sessions;
  }

  /** Create or resume a named session on an explicitly selected online device. */
  async session(options: { deviceId: string; session: string; model?: string; maxModelCalls?: number }): Promise<ManagedSession> {
    if (!DEVICE.test(options.deviceId) || !SESSION.test(options.session)) throw new Error("Invalid device/session identifier");
    const result = await this.request<{ session_id: string }>("POST", `/v1/remote/agents/${options.deviceId}/sessions`, {
      session: options.session,
      ...(options.model ? { model: options.model } : {}),
      ...(options.maxModelCalls === undefined ? {} : { max_model_calls: options.maxModelCalls }),
    });
    return this.attach(result.session_id);
  }

  /** Attach without creating a device, replacing a process or changing its model. */
  attach(sessionId: string): ManagedSession {
    if (!SESSION.test(sessionId)) throw new Error("Invalid session identifier");
    return new ManagedSession(sessionId, this.request.bind(this), this.options.observe, this.retries);
  }
}

type Request = <T>(method: string, path: string, body?: unknown, signal?: AbortSignal) => Promise<T>;
type Page = { events: string[]; next_from: number; in_flight: boolean; gap: boolean };

export class ManagedSession {
  constructor(readonly sessionId: string, private readonly request: Request,
    private readonly observe: SpanObserver | undefined, private readonly retries: number) {}

  async status(): Promise<ManagedSessionInfo | null> {
    const result = await this.request<{ sessions: ManagedSessionInfo[] }>("GET", "/v1/remote/sessions");
    return result.sessions.find(s => s.session_id === this.sessionId) ?? null;
  }

  /** A 202 acknowledges durable relay enqueue, NOT a completed model turn.
   * A lost POST response is ambiguous: do not blindly submit again. The engine's
   * recent message-id dedupe is bounded/in-memory, not crash-safe exactly-once.
   */
  async submit(prompt: string, options: { messageId: string }): Promise<ManagedReceipt> {
    if (!options.messageId || options.messageId.length > 128) throw new Error("messageId must contain 1..128 characters");
    const startedUnixNano = nano();
    const result = await this.request<{ command_id: string; from: number }>("POST", `/v1/remote/sessions/${this.sessionId}`, {
      type: "user", text: prompt, message_id: options.messageId,
    });
    if (!integer(result.from) || typeof result.command_id !== "string") throw new Error("Invalid managed submission receipt");
    return { sessionId: this.sessionId, commandId: result.command_id, messageId: options.messageId,
      from: result.from, traceId: hex(16), spanId: hex(8), startedUnixNano };
  }

  /** Replay then follow a previously accepted turn, including in a new process.
   * Resumes reads only; a socket failure never resends the prompt. Aborting a
   * watch detaches the viewer; call cancel() separately to stop execution.
   * One active prompt per session is required; receipts do not fence writers.
   */
  async *watch(receipt: ManagedReceipt, options: { from?: number; signal?: AbortSignal } = {}): AsyncGenerator<Event> {
    if (receipt.sessionId !== this.sessionId) throw new Error("Receipt belongs to another session");
    let from = options.from ?? receipt.from;
    if (!integer(from)) throw new Error("Invalid replay cursor");
    let failures = 0;
    let gaps = 0;
    let count = 0;
    let reconnects = 0;
    while (true) {
      options.signal?.throwIfAborted();
      let page: Page;
      try {
        page = await this.request<Page>("GET", `/v1/remote/sessions/${this.sessionId}/events?from=${from}&wait=25000`, undefined, options.signal);
      } catch (error) {
        options.signal?.throwIfAborted();
        if (error instanceof ManagedRequestError && error.status < 500 && error.status !== 429) throw error;
        if (failures++ >= this.retries) throw error;
        reconnects++;
        continue;
      }
      if (page.gap) {
        if (++gaps > 3) throw new Error("Event tape gap could not be recovered; cursor was not advanced");
        await this.request("POST", `/v1/remote/sessions/${this.sessionId}`, { type: "reattach", resume_from: from }, options.signal);
        reconnects++;
        continue;
      }
      if (!Array.isArray(page.events)) throw new Error("Invalid managed event page");
      for (const line of page.events) {
        const event = JSON.parse(line) as Event & { truncated?: boolean };
        if (!integer(event.seq) || typeof event.type !== "string") throw new Error("Invalid managed event envelope");
        if (event.seq < from) continue;
        if (event.truncated) throw new Error("Event exceeds relay window limit; use the device tape to retrieve it");
        from = event.seq + 1;
        count++;
        failures = 0;
        if (event.type === "turn" || event.type === "error") {
          const attributes: Record<string, number> = { "graff.events": count, "graff.reconnects": reconnects };
          if (event.type === "turn") {
            for (const [key, value] of [
              ["gen_ai.usage.input_tokens", event.input_tokens], ["gen_ai.usage.output_tokens", event.output_tokens],
              ["gen_ai.usage.cache_read_tokens", event.cache_read_tokens], ["graff.api_calls", event.api_calls],
            ] as const) if (typeof value === "number" && Number.isFinite(value)) attributes[key] = value;
          }
          const span: TraceSpan = { traceId: receipt.traceId, spanId: receipt.spanId, name: "graff.turn",
            startTimeUnixNano: receipt.startedUnixNano, endTimeUnixNano: nano(),
            status: { code: event.type === "error" ? 2 : 1 }, attributes };
          // Observers cannot fail or hold completion open; flush exporters separately.
          try { void Promise.resolve(this.observe?.(span)).catch(() => {}); } catch { /* content-free best effort */ }
          yield event;
          return;
        }
        yield event;
      }
      if (!page.in_flight && page.events.length === 0) {
        // Ring state is volatile across a relay restart. Ask the device for its
        // tape once rather than treating an idle/empty window as completion.
        if (++gaps > 3) throw new Error("No terminal event on the device tape; execution state is unknown");
        await this.request("POST", `/v1/remote/sessions/${this.sessionId}`, { type: "reattach", resume_from: from }, options.signal);
        reconnects++;
      }
    }
  }

  async cancel(): Promise<void> {
    await this.request("POST", `/v1/remote/sessions/${this.sessionId}`, { type: "cancel" });
  }

  async answer(text: string, callId?: string): Promise<void> {
    await this.request("POST", `/v1/remote/sessions/${this.sessionId}`, { type: "answer", text, ...(callId ? { call_id: callId } : {}) });
  }

  /** Explicitly stop/close the remote session, not just the local watcher. */
  async close(): Promise<void> {
    await this.request("DELETE", `/v1/remote/sessions/${this.sessionId}`);
  }
}
