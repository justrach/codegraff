import { describe, expect, spyOn, test } from "bun:test";
import { createOtlpExporter, type TraceSpan } from "./otel.ts";

const url = "https://collector.test/v1/traces";
const apiKey = "synthetic-secret-key";
const span = (overrides: Partial<TraceSpan> = {}): TraceSpan => ({
  traceId: "abcdef0123456789abcdef0123456789",
  spanId: "0123456789abcdef",
  name: "graff.turn",
  startTimeUnixNano: "1700000000000000000",
  endTimeUnixNano: "1700000001000000000",
  ...overrides,
});

type Capture = { url: string; init: RequestInit; payload: any };
function collector() {
  const calls: Capture[] = [];
  const fetcher = (async (input, init) => {
    calls.push({ url: String(input), init: init!, payload: JSON.parse(String(init!.body)) });
    return new Response(null, { status: 200 });
  }) as typeof fetch;
  return { calls, fetcher };
}
const spans = (call: Capture): any[] => call.payload.resourceSpans[0].scopeSpans[0].spans;
const deferred = <T>() => {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
};

async function fetchStarted() {
  // flush and the fetch adapter each defer one microtask.
  for (let i = 0; i < 5; i++) await Promise.resolve();
}

describe("metadata-only OTLP exporter", () => {
  test("is opt-in and emits OTLP JSON, fixed service and typed numeric/boolean attributes", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    await exporter.flush();
    expect(calls).toHaveLength(0);
    exporter.observe(span({
      parentSpanId: "FEDCBA9876543210",
      status: { code: 1 },
      attributes: {
        "graff.events": 12,
        "graff.reconnects": true,
        "gen_ai.usage.input_tokens": 23,
        "gen_ai.usage.output_tokens": 4,
        "gen_ai.usage.cache_read_tokens": 2,
        "graff.api_calls": 1.5,
      },
    }));
    expect(calls).toHaveLength(0);
    await exporter.flush();
    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.url).toBe(url);
    expect(call.init.method).toBe("POST");
    expect(call.init.headers).toEqual({
      "Content-Type": "application/json", Authorization: `Bearer ${apiKey}`,
    });
    expect(call.init.redirect).toBe("manual");
    expect(call.init.credentials).toBe("omit");
    expect(call.init.referrerPolicy).toBe("no-referrer");
    expect(call.payload.resourceSpans).toHaveLength(1);
    expect(call.payload.resourceSpans[0].resource).toEqual({ attributes: [
      { key: "service.name", value: { stringValue: "codegraff-sdk" } },
    ] });
    expect(spans(call)).toEqual([{
      ...span(), parentSpanId: "fedcba9876543210", status: { code: 1 },
      attributes: [
        { key: "graff.events", value: { intValue: "12" } },
        { key: "graff.reconnects", value: { boolValue: true } },
        { key: "gen_ai.usage.input_tokens", value: { intValue: "23" } },
        { key: "gen_ai.usage.output_tokens", value: { intValue: "4" } },
        { key: "gen_ai.usage.cache_read_tokens", value: { intValue: "2" } },
        { key: "graff.api_calls", value: { doubleValue: 1.5 } },
      ],
    }]);
    expect(exporter.dropped).toBe(0);
    await exporter.flush();
    expect(calls).toHaveLength(1);
  });

  test("rebuilds a snapshot and excludes content, model/tool/session/resource names and API key", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    const original = Object.assign(span({ attributes: {
      "graff.events": 3,
      "gen_ai.usage.input_tokens": "forbidden-input" as any,
      "gen_ai.usage.output_tokens": NaN,
      "gen_ai.usage.cache_read_tokens": Infinity,
      "graff.api_calls": { toJSON: () => "forbidden-value" } as any,
      "custom.attribute": 123,
      "session.id": 456,
      "gen_ai.request.model": 789,
    } }), {
      content: "forbidden-content", model: "forbidden-model", tool: "forbidden-tool",
      session_id: "forbidden-session", resource: { name: "forbidden-resource" },
      apiKey, toJSON: () => ({ content: "forbidden-toJSON" }),
    });
    exporter.observe(original);
    original.name = "graff.tool";
    original.attributes!["graff.events"] = 999;
    await exporter.flush();
    const body = String(calls[0]!.init.body);
    for (const forbidden of ["forbidden", apiKey, "custom.attribute", "session.id", "gen_ai.request.model"])
      expect(body).not.toContain(forbidden);
    expect(spans(calls[0]!)[0].name).toBe("graff.turn");
    expect(spans(calls[0]!)[0].attributes).toEqual([
      { key: "graff.events", value: { intValue: "3" } },
    ]);
  });

  test("ignores attribute accessors/inherited values and isolates throwing input", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    const attributes = Object.create({ "graff.api_calls": 7 });
    Object.defineProperty(attributes, "graff.events", { get() { throw new Error("private"); } });
    exporter.observe(span({ attributes }));
    expect(() => exporter.observe(new Proxy(span(), {
      get() { throw new Error("private"); },
    }))).not.toThrow();
    expect(() => exporter.observe(null as any)).not.toThrow();
    await exporter.flush();
    expect(spans(calls[0]!)[0].attributes).toBeUndefined();
    expect(exporter.dropped).toBe(2);
  });

  test("rejects invalid IDs, names, uint64 timestamps, reversed time and status", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    const bad: Partial<TraceSpan>[] = [
      { traceId: "0".repeat(32) }, { traceId: "a".repeat(31) },
      { traceId: "g".repeat(32) }, { traceId: 4 as any },
      { spanId: "0".repeat(16) }, { spanId: "a".repeat(17) },
      { parentSpanId: "0".repeat(16) }, { parentSpanId: "private" },
      { name: "private-tool-name" as any },
      { startTimeUnixNano: "-1" }, { startTimeUnixNano: "1.5" },
      { startTimeUnixNano: "01" }, { startTimeUnixNano: "1e9" },
      { startTimeUnixNano: 123 as any }, { endTimeUnixNano: "" },
      { endTimeUnixNano: "18446744073709551616" },
      { endTimeUnixNano: "1" }, { status: { code: 3 } as any },
    ];
    for (const overrides of bad) exporter.observe(span(overrides));
    await exporter.flush();
    expect(calls).toHaveLength(0);
    expect(exporter.dropped).toBe(bad.length);
    exporter.observe(span({
      traceId: "ABCDEF0123456789ABCDEF0123456789",
      startTimeUnixNano: "0", endTimeUnixNano: "18446744073709551615",
      status: { code: 0 },
    }));
    await exporter.flush();
    expect(spans(calls[0]!)[0].traceId).toBe(span().traceId);
    expect(exporter.dropped).toBe(bad.length);
  });

  test("supports only the four lifecycle names and strips status descriptions", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    for (const name of ["graff.turn", "graff.model", "graff.tool", "graff.reconnect"] as const)
      exporter.observe(span({ name, status: { code: 2, message: "private" } as any }));
    await exporter.flush();
    expect(spans(calls[0]!).map((s) => s.name)).toEqual([
      "graff.turn", "graff.model", "graff.tool", "graff.reconnect",
    ]);
    expect(String(calls[0]!.init.body)).not.toContain("private");
  });

  test("validates endpoint and configuration without reflecting sensitive input", () => {
    const { fetcher } = collector();
    for (const invalid of [
      "http://collector.test", "ftp://localhost", "https://user:private@collector.test",
      "https://@collector.test", `${url}?key=private`, `${url}#private`,
      `${url}?`, `${url}#`, "http://localhost.collector.test", "http://128.0.0.1",
      "not-a-url-private", "https:\\\\@collector.test", "https://\t@collector.test",
    ]) {
      expect(() => createOtlpExporter({ url: invalid, apiKey, fetch: fetcher }))
        .toThrow("Invalid OTLP endpoint");
      try { createOtlpExporter({ url: invalid, apiKey, fetch: fetcher }); }
      catch (error) { expect(String(error)).not.toContain("private"); }
    }
    for (const valid of [url, "http://localhost:4318/v1/traces", "http://127.0.0.1",
      "http://127.42.0.2", "http://[::1]:4318/v1/traces"])
      expect(() => createOtlpExporter({ url: valid, apiKey, fetch: fetcher })).not.toThrow();
    for (const timeoutMs of [0, -1, NaN, Infinity])
      expect(() => createOtlpExporter({ url, apiKey, timeoutMs })).toThrow("Invalid OTLP timeout");
    for (const key of ["", " ", "private\r\nHeader: value"])
      expect(() => createOtlpExporter({ url, apiKey: key })).toThrow("Invalid OTLP authorization");
  });

  test("bounds pending spans and payload bytes with all allowed attributes populated", async () => {
    const { calls, fetcher } = collector();
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    const full = span({ parentSpanId: "a".repeat(16), status: { code: 2 }, attributes: {
      "graff.events": -Number.MAX_VALUE, "graff.reconnects": Number.MAX_SAFE_INTEGER,
      "gen_ai.usage.input_tokens": Number.MIN_VALUE,
      "gen_ai.usage.output_tokens": -Number.MAX_SAFE_INTEGER,
      "gen_ai.usage.cache_read_tokens": Number.MAX_VALUE, "graff.api_calls": false,
    } });
    for (let i = 0; i < 1000; i++) exporter.observe(full);
    await exporter.flush();
    const accepted = calls.reduce((n, call) => n + spans(call).length, 0);
    expect(accepted).toBeGreaterThan(0);
    expect(accepted).toBeLessThanOrEqual(64);
    expect(exporter.dropped).toBe(1000 - accepted);
    for (const call of calls) expect(new TextEncoder().encode(String(call.init.body)).length)
      .toBeLessThanOrEqual(64 * 1024);
    exporter.observe(span());
    await exporter.flush();
    expect(spans(calls.at(-1)!)).toHaveLength(1);
  });

  test("concurrent/reentrant flushes share a drain, retain new observations and bound in-flight spans", async () => {
    const first = deferred<Response>();
    const calls: string[] = [];
    let exporter: ReturnType<typeof createOtlpExporter>;
    let reentrant: Promise<void> | undefined;
    const fetcher = (() => {
      calls.push("request");
      reentrant = exporter.flush();
      return calls.length === 1 ? first.promise : Promise.resolve(new Response(null));
    }) as unknown as typeof fetch;
    exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
    exporter.observe(span());
    const flush = exporter.flush();
    expect(exporter.flush()).toBe(flush);
    await fetchStarted();
    expect(reentrant).toBe(flush);
    for (let i = 0; i < 64; i++) exporter.observe(span());
    expect(exporter.dropped).toBe(1); // one in-flight plus 63 queued
    expect(calls).toHaveLength(1);
    first.resolve(new Response(null));
    await Promise.all([flush, exporter.flush(), exporter.flush()]);
    expect(calls).toHaveLength(2);
    expect(exporter.dropped).toBe(1);
    await exporter.flush();
    expect(calls).toHaveLength(2);
  });

  test("does not strand observations arriving at the drain completion boundary", async () => {
    for (let delay = 0; delay < 20; delay++) {
      const { calls, fetcher } = collector();
      const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
      exporter.observe(span());
      const first = exporter.flush();
      for (let tick = 0; tick < delay; tick++) await Promise.resolve();
      exporter.observe(span());
      await Promise.all([first, exporter.flush()]);
      expect(calls.reduce((n, call) => n + spans(call).length, 0)).toBe(2);
      expect(exporter.dropped).toBe(0);
    }
  });

  test("isolates network, synchronous fetch, HTTP and redirect failures without reading bodies or retrying", async () => {
    for (const mode of ["reject", "throw", "http", "redirect"] as const) {
      let calls = 0;
      let reads = 0;
      let cancels = 0;
      const fetcher = (() => {
        calls++;
        if (mode === "throw") throw new Error(apiKey);
        if (mode === "reject") return Promise.reject(new Error(apiKey));
        return Promise.resolve({
          ok: false, status: mode === "http" ? 503 : 302,
          text() { reads++; throw new Error(apiKey); },
          json() { reads++; throw new Error(apiKey); },
          body: { cancel() { cancels++; return Promise.reject(new Error(apiKey)); } },
        } as unknown as Response);
      }) as unknown as typeof fetch;
      const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher });
      exporter.observe(span());
      exporter.observe(span());
      await expect(exporter.flush()).resolves.toBeUndefined();
      await exporter.flush();
      expect(exporter.dropped).toBe(2);
      expect(calls).toBe(1);
      expect(reads).toBe(0);
      expect(cancels).toBe(mode === "http" || mode === "redirect" ? 1 : 0);
    }
  });

  test("times out abort-ignoring fetch, consumes late rejection, and can export again", async () => {
    const late = deferred<Response>();
    let signal: AbortSignal | undefined;
    let calls = 0;
    const fetcher = ((_input, init) => {
      calls++;
      signal = init!.signal!;
      return calls === 1 ? late.promise : Promise.resolve(new Response(null));
    }) as typeof fetch;
    const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher, timeoutMs: 5 });
    exporter.observe(span());
    await expect(exporter.flush()).resolves.toBeUndefined();
    expect(signal?.aborted).toBe(true);
    expect(exporter.dropped).toBe(1);
    late.reject(new Error(apiKey));
    exporter.observe(span());
    await exporter.flush();
    expect(calls).toBe(2);
    expect(exporter.dropped).toBe(1);
  });

  test("uses a 5s default, caps timeouts at 30s and clears timers after flush", async () => {
    const originalTimeout = globalThis.setTimeout;
    const delays: number[] = [];
    const timeoutSpy = spyOn(globalThis, "setTimeout").mockImplementation(((handler: () => void, delay?: number) => {
      delays.push(delay!);
      return originalTimeout(handler, 1);
    }) as typeof setTimeout);
    const clearSpy = spyOn(globalThis, "clearTimeout");
    try {
      for (const timeoutMs of [undefined, 60000, 15]) {
        const fetcher = (() => new Promise<Response>(() => {})) as unknown as typeof fetch;
        const exporter = createOtlpExporter({ url, apiKey, fetch: fetcher, timeoutMs });
        exporter.observe(span());
        await exporter.flush();
        expect(exporter.dropped).toBe(1);
      }
      expect(delays).toEqual([5000, 30000, 15]);
      expect(clearSpy).toHaveBeenCalledTimes(3);
    } finally {
      timeoutSpy.mockRestore();
      clearSpy.mockRestore();
    }
  });
});
