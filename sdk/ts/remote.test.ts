import { afterEach, describe, expect, test } from "bun:test";
import { RemoteHarness, runAgentRemote, type Event } from "./remote.ts";

const originalFetch = globalThis.fetch;
const live: RemoteHarness[] = [];
const enc = new TextEncoder();
type InputEvent = Event extends infer T ? T extends { seq: number } ? Omit<T, "seq"> : never : never;
const line = (event: Event) => enc.encode(`${JSON.stringify(event)}\n`);

class FakeBridge {
  requests: string[] = [];
  bodies: Record<string, unknown>[] = [];
  readerCancels = 0;
  active?: ReadableStreamDefaultController<Uint8Array>;
  seq = 0;

  event(event: InputEvent): Event {
    return { seq: ++this.seq, ...event } as Event;
  }

  stream(events: InputEvent[], keepOpen = true): Response {
    const bridge = this;
    return new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        for (const event of events) controller.enqueue(line(bridge.event(event)));
        if (!keepOpen) controller.close();
      },
      cancel() { bridge.readerCancels += 1; },
    }), { status: 200, headers: { "content-type": "application/x-ndjson" } });
  }

  fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = new URL(String(input));
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    if (url.pathname === "/v1/sessions") {
      return Response.json({ session_id: "s1", resumed: false, last_seq: 0 });
    }
    if (init?.method === "DELETE") return Response.json({ ok: true });
    const type = String(body.type ?? "reattach");
    this.requests.push(type);
    this.bodies.push(body);
    if (type === "cancel") {
      this.active?.enqueue(line(this.event({ type: "error", message: "turn cancelled" })));
      this.active = undefined;
      return Response.json({ ok: true, type: "cancel" });
    }
    if (type === "answer") {
      this.active?.enqueue(line(this.event({
        type: "turn", text: `answered:${String(body.text)}`, context_tokens: 1,
        cost_usd: 0, input_tokens: 1, uncached_input_tokens: 1,
        cache_read_tokens: 0, output_tokens: 1, api_calls: 1,
        subscription_calls: 0, unpriced_calls: 0, complete: true,
        metadata_complete: true,
      })));
      this.active = undefined;
      return Response.json({ ok: true, type: "answer" });
    }
    if (type === "user" || type === "review") {
      const text = String(body.text);
      if (text === "slow" || text === "ask") {
        const bridge = this;
        return new Response(new ReadableStream<Uint8Array>({
          start(controller) {
            bridge.active = controller;
            controller.enqueue(line(bridge.event(text === "ask"
              ? { type: "ask_user", call_id: "r-ask", question: "continue?", input: {} }
              : { type: "started", provider: "fake", model: "fake" })));
          },
          cancel() { bridge.readerCancels += 1; },
        }), { status: 200 });
      }
      return this.stream([{
        type: "turn", text: `${type}:${text}`, context_tokens: 9,
        cost_usd: 0.1, input_tokens: 5, uncached_input_tokens: 2,
        cache_read_tokens: 3, output_tokens: 4, api_calls: 1,
        subscription_calls: 1, unpriced_calls: 0, complete: true,
        metadata_complete: true,
      }]);
    }
    if (type === "set_model") return String(body.model) === "bad"
      ? this.stream([{ type: "error", message: "bad model" }])
      : this.stream([{
        type: "model", ok: true, provider: String(body.provider), model: String(body.model), context: 100, note: "",
      }]);
    if (type === "set_effort") return this.stream([{
      type: "effort", ok: true, level: String(body.level), applies: true,
    }]);
    if (type === "compact") return this.stream([{ type: "compact", ok: true, chars: 3 }]);
    if (type === "reattach") return this.stream([{
      type: "turn", text: "replayed", context_tokens: 1, cost_usd: 0,
      input_tokens: 1, uncached_input_tokens: 1, cache_read_tokens: 0,
      output_tokens: 1, api_calls: 1, subscription_calls: 0,
      unpriced_calls: 0, complete: true, metadata_complete: true,
    }], false);
    throw new Error(`unexpected request ${type}`);
  };
}

const use = (bridge: FakeBridge) => {
  globalThis.fetch = bridge.fetch as typeof fetch;
  const h = new RemoteHarness({ url: "http://bridge.test" });
  live.push(h);
  return h;
};

const waitFor = async (predicate: () => boolean) => {
  for (let i = 0; i < 100 && !predicate(); i += 1) await Bun.sleep(5);
  if (!predicate()) throw new Error("condition timed out");
};

afterEach(async () => {
  for (const value of live.splice(0)) await value.close();
  globalThis.fetch = originalFetch;
});

describe("RemoteHarness transport", () => {
  test("serializes turns and controls and releases terminal response readers", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const turn = h.askResult("one");
    const model = h.setModel("codex", "gpt-test");
    const effort = h.setEffort("xhigh");
    const compact = h.compact();
    const result = await turn;
    await Promise.all([model, effort, compact]);

    expect(result.text).toBe("user:one");
    expect(result.cacheReadTokens).toBe(3);
    expect(bridge.requests.slice(0, 4)).toEqual(["user", "set_model", "set_effort", "compact"]);
    expect(bridge.readerCancels).toBeGreaterThanOrEqual(4);
  });

  test("a failed control does not poison the operation queue", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    await expect(h.setModel("codex", "bad")).rejects.toThrow("bad model");
    expect(await h.ask("after-error")).toBe("user:after-error");
  });

  test("serializes URL and base64 images as native protocol parts", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    expect(await h.ask({
      prompt: "read the code",
      images: [
        { type: "image_url", url: "https://images.test/code.png" },
        { type: "image_base64", mediaType: "image/png", data: "aGVsbG8=" },
      ],
    })).toBe("user:read the code");
    expect(bridge.bodies.find((body) => body.type === "user")?.images).toEqual([
      { type: "image_url", url: "https://images.test/code.png" },
      { type: "image_base64", media_type: "image/png", data: "aGVsbG8=" },
    ]);
  });

  test("one-shot runAgentRemote preserves native image parts", async () => {
    const bridge = new FakeBridge();
    globalThis.fetch = bridge.fetch as typeof fetch;
    for await (const _event of runAgentRemote({
      url: "http://bridge.test",
      prompt: "read the code",
      images: [{ type: "image_url", url: "https://images.test/one-shot.png" }],
    })) {}
    expect(bridge.bodies.find((body) => body.type === "user")?.images).toEqual([
      { type: "image_url", url: "https://images.test/one-shot.png" },
    ]);
  });

  test("AbortSignal sends an out-of-band cancel and later turns still work", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const controller = new AbortController();
    const pending = h.ask({ prompt: "slow", signal: controller.signal });
    await waitFor(() => bridge.requests.includes("user"));
    controller.abort();
    await expect(pending).rejects.toThrow("turn cancelled");
    expect(bridge.requests).toContain("cancel");
    expect(await h.ask("after")).toBe("user:after");
  });

  test("answer bypasses the active ask_user stream", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    let final = "";
    for await (const event of h.chat("ask")) {
      if (event.type === "ask_user") await h.answer({ text: "yes", callId: event.call_id });
      if (event.type === "turn") final = event.text;
    }
    expect(final).toBe("answered:yes");
  });

  test("reconnect replays from the requested sequence and updates lastSeq", async () => {
    const bridge = new FakeBridge();
    const h = use(bridge);
    const events = [];
    for await (const event of h.reconnect(7)) events.push(event);
    expect(events.at(-1)?.type).toBe("turn");
    expect(h.lastSeq).toBeGreaterThan(0);
    expect(bridge.requests).toContain("reattach");
  });

  test("constructor observes create rejection even when the caller never awaits it", async () => {
    let unhandled = 0;
    const listener = () => { unhandled += 1; };
    process.on("unhandledRejection", listener);
    globalThis.fetch = (async () => { throw new Error("create failed"); }) as unknown as typeof fetch;
    const h = new RemoteHarness({ url: "http://bridge.test" });
    live.push(h);
    await Bun.sleep(30);
    // Current @types/node overloads collapse off/removeListener to memoryPressure.
    (process as NodeJS.EventEmitter).removeListener("unhandledRejection", listener);
    expect(unhandled).toBe(0);
    await expect(h.sessionId).rejects.toThrow("create failed");
  });
});
