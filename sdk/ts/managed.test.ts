import { describe, expect, test } from "bun:test";
import { ManagedHarness, ManagedRequestError } from "./managed.ts";
import type { ManagedReceipt } from "./managed.ts";
import type { TraceSpan } from "./otel.ts";

const sid = "sdk-smoke";
const device = "1234567890abcdef";
const receipt: ManagedReceipt = { sessionId: sid, commandId: "command", messageId: "message", from: 1,
  traceId: "a".repeat(32), spanId: "b".repeat(16), startedUnixNano: "1790000000000000000" };
const turn = { seq: 3, type: "turn", text: "sensitive answer", input_tokens: 12, output_tokens: 2, api_calls: 1 };
function fake(fn: (path: string, init: RequestInit) => Response | Promise<Response>): typeof fetch {
  return (async (url: string | URL | Request, init: RequestInit = {}) => fn(String(url), init)) as typeof fetch;
}
const page = (events: unknown[], extra = {}) => Response.json({ events: events.map(x => JSON.stringify(x)), in_flight: false, gap: false, next_from: 4, ...extra });

describe("managed relay SDK", () => {
  test("creation uses an explicit device; keys stay in auth headers", async () => {
    const requests: string[] = [];
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake((url, init) => {
      expect((init.headers as Record<string, string>).Authorization).toBe("Bearer test-key");
      expect(init.redirect).toBe("manual");
      expect(url).not.toContain("test-key");
      expect(String(init.body)).not.toContain("test-key");
      requests.push(url);
      if (url.endsWith(`/agents/${device}/sessions`)) {
        expect(JSON.parse(String(init.body))).toEqual({ session: sid, model: "example", max_model_calls: 2 });
        return Response.json({ session_id: sid });
      }
      return Response.json({ sessions: [{ session_id: sid, online: true }] });
    }) });
    const session = await h.session({ deviceId: device, session: sid, model: "example", maxModelCalls: 2 });
    expect((await session.status())?.online).toBe(true);
    expect(requests).toHaveLength(2);
  });

  test("a new SDK process reattaches with receipt/cursor; GET failure never resends a prompt", async () => {
    let reads = 0; let prompts = 0;
    const observed: TraceSpan[] = [];
    const fetcher = fake((_url, init) => {
      if (init.method === "POST") {
        prompts++;
        expect(JSON.parse(String(init.body)).message_id).toBe("my-id");
        return Response.json({ command_id: "accepted", from: 1 }, { status: 202 });
      }
      if (++reads === 1) throw new TypeError("connection dropped");
      return page([{ seq: 1, type: "text", text: "private prompt/tool text" }, turn]);
    });
    const first = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fetcher });
    const accepted = await first.attach(sid).submit("sensitive prompt", { messageId: "my-id" });
    const persisted = JSON.parse(JSON.stringify(accepted)) as ManagedReceipt;
    const second = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fetcher,
      observe: s => { observed.push(s); } });
    const events = [];
    for await (const ev of second.attach(sid).watch(persisted)) events.push(ev);
    expect(events.map(e => e.seq)).toEqual([1, 3]);
    expect(prompts).toBe(1);
    expect(reads).toBe(2);
    expect(observed).toHaveLength(1);
    expect(JSON.stringify(observed)).not.toMatch(/sensitive|private|test-key|my-id|accepted/);
    expect(observed[0]?.attributes?.["graff.reconnects"]).toBe(1);
  });

  test("gap recovery discards incomplete window, requests device replay, and removes old duplicates", async () => {
    let reads = 0; let replays = 0;
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake((_url, init) => {
      if (init.method === "POST") {
        replays++;
        expect(JSON.parse(String(init.body))).toEqual({ type: "reattach", resume_from: 2 });
        return Response.json({ ok: true });
      }
      if (++reads === 1) return page([turn], { gap: true });
      return page([{ seq: 1, type: "text", text: "already committed" }, { seq: 2, type: "text", text: "new" }, turn]);
    }) });
    const events = [];
    for await (const e of h.attach(sid).watch(receipt, { from: 2 })) events.push(e.seq);
    expect(events).toEqual([2, 3]);
    expect(replays).toBe(1);
  });

  test("empty idle window after relay restart requests tape rather than inventing completion", async () => {
    let reads = 0; let replays = 0;
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake((_url, init) => {
      if (init.method === "POST") { replays++; return Response.json({}); }
      return ++reads === 1 ? page([]) : page([turn]);
    }) });
    for await (const _event of h.attach(sid).watch(receipt)) { /* drain */ }
    expect(replays).toBe(1);
  });

  test("ambiguous submission is not retried; auth failures are terminal and sanitized", async () => {
    let calls = 0;
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake(() => {
      calls++; return Response.json({ secret: "must not appear" }, { status: 403 });
    }) });
    await expect(h.attach(sid).submit("prompt", { messageId: "id" })).rejects.toBeInstanceOf(ManagedRequestError);
    expect(calls).toBe(1);
    await expect((async () => { for await (const _e of h.attach(sid).watch(receipt)) { /* drain */ } })()).rejects.toThrow("HTTP 403");
    expect(calls).toBe(2);
  });

  test("truncated events fail without silently advancing a cursor", async () => {
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake(() => page([{ seq: 1, type: "text", truncated: true }])) });
    await expect((async () => { for await (const _e of h.attach(sid).watch(receipt)) { /* drain */ } })()).rejects.toThrow("device tape");
  });

  test("cancel and answer bypass watch; aborting a watch does not stop remote work", async () => {
    const types: string[] = [];
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake((_url, init) => {
      types.push(JSON.parse(String(init.body)).type); return Response.json({});
    }) });
    const session = h.attach(sid);
    await session.cancel(); await session.answer("continue", "call");
    const ac = new AbortController(); ac.abort();
    await expect((async () => { for await (const _e of session.watch(receipt, { signal: ac.signal })) { /* drain */ } })()).rejects.toThrow();
    expect(types).toEqual(["cancel", "answer"]);
  });

  test("throwing, rejecting and stalled observers cannot hold a completed turn open", async () => {
    for (const observe of [
      () => { throw new Error("export failed"); },
      () => Promise.reject(new Error("export rejected")),
      () => new Promise<void>(() => {}),
    ]) {
      const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake(() => page([turn])), observe });
      const types = [];
      for await (const e of h.attach(sid).watch(receipt)) types.push(e.type);
      expect(types).toEqual(["turn"]);
    }
  });

  test("native fetch keeps the global receiver required by Workers", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = (function (this: unknown) {
      expect(this).toBe(globalThis);
      return Promise.resolve(Response.json({ sessions: [] }));
    }) as unknown as typeof fetch;
    try {
      const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key" });
      expect(await h.sessions()).toEqual([]);
    } finally { globalThis.fetch = original; }
  });

  test("manual redirects fail without following the location or retrying", async () => {
    let calls = 0;
    const h = new ManagedHarness({ url: "https://relay.example", apiKey: "test-key", fetch: fake((_url, init) => {
      calls++;
      expect(init.redirect).toBe("manual");
      return new Response(null, { status: 302, headers: { location: "https://must-not-follow.example" } });
    }) });
    await expect(h.sessions()).rejects.toThrow("HTTP 302");
    expect(calls).toBe(1);
  });

  test("rejects credential-bearing, insecure and malformed URLs/identifiers", () => {
    for (const url of ["http://remote.example", "https://user:pass@relay.example", "https://relay.example?key=secret", "https://relay.example/#x"]) {
      expect(() => new ManagedHarness({ url, apiKey: "test-key" })).toThrow();
    }
    const h = new ManagedHarness({ url: "http://127.0.0.1:8080", apiKey: "test-key" });
    expect(() => h.attach("../bad")).toThrow();
  });
});
