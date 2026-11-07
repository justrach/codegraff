/** Opt-in, metadata-only OTLP/HTTP JSON export; no background work or retries. */
export type TraceSpan = {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  name: "graff.turn" | "graff.model" | "graff.tool" | "graff.reconnect";
  startTimeUnixNano: string;
  endTimeUnixNano: string;
  status?: { code: 0 | 1 | 2 };
  attributes?: Record<string, number | boolean>;
};

export type SpanObserver = (span: TraceSpan) => void | Promise<void>;

type Options = {
  url: string;
  apiKey: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
};

type Attribute = {
  key: string;
  value: { boolValue: boolean } | { intValue: string } | { doubleValue: number };
};

const ATTRIBUTE_KEYS = [
  "graff.events",
  "graff.reconnects",
  "gen_ai.usage.input_tokens",
  "gen_ai.usage.output_tokens",
  "gen_ai.usage.cache_read_tokens",
  "graff.api_calls",
] as const;
const NAMES = new Set(["graff.turn", "graff.model", "graff.tool", "graff.reconnect"]);
const MAX_SPANS = 64;
const MAX_BYTES = 64 * 1024;
const PREFIX = '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codegraff-sdk"}}]},"scopeSpans":[{"spans":[';
const SUFFIX = ']}]}]}';

function endpoint(input: string): string {
  try {
    if (typeof input !== "string" || !/^https?:\/\//i.test(input)
      || /[\u0000-\u0020\\]/.test(input)) throw new Error();
    const url = new URL(input);
    const loopback = url.hostname === "localhost" || url.hostname === "[::1]"
      || /^127\.\d+\.\d+\.\d+$/.test(url.hostname);
    // Check the serialized URL too: URL.search/hash hide empty '?' and '#'.
    const authority = url.href.slice(url.protocol.length + 2).split("/")[0]!;
    if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback))
      || url.username || url.password || authority.includes("@")
      || url.href.includes("?") || url.href.includes("#")) throw new Error();
    // URL normalizes empty userinfo away, so reject it in the input as well.
    if (/^[^:]+:\/\/[^/]*@/.test(input.trim())) throw new Error();
    return url.href;
  } catch {
    throw new TypeError("Invalid OTLP endpoint: HTTPS (or loopback HTTP) without userinfo, query or fragment required");
  }
}

function id(value: unknown, length: number): value is string {
  return typeof value === "string" && value.length === length
    && /^[0-9a-f]+$/i.test(value) && !/^0+$/.test(value);
}

function timestamp(value: unknown): value is string {
  return typeof value === "string" && /^(0|[1-9]\d{0,19})$/.test(value)
    && BigInt(value) <= 18446744073709551615n;
}

/** Reconstruct from primitives, never serialize caller objects or their toJSON. */
function serialize(span: TraceSpan): string | undefined {
  const { traceId, spanId, parentSpanId, name, startTimeUnixNano, endTimeUnixNano } = span;
  if (!id(traceId, 32) || !id(spanId, 16)
    || (parentSpanId !== undefined && !id(parentSpanId, 16))
    || !NAMES.has(name) || typeof name !== "string"
    || !timestamp(startTimeUnixNano) || !timestamp(endTimeUnixNano)
    || BigInt(endTimeUnixNano) < BigInt(startTimeUnixNano)) return;
  const attributes: Attribute[] = [];
  const source = span.attributes;
  if (source && typeof source === "object") {
    for (const key of ATTRIBUTE_KEYS) {
      // Accessors and inherited properties are not lifecycle metadata.
      const value: unknown = Object.getOwnPropertyDescriptor(source, key)?.value;
      if (typeof value === "boolean") attributes.push({ key, value: { boolValue: value } });
      else if (typeof value === "number" && Number.isFinite(value)) {
        attributes.push({ key, value: Number.isSafeInteger(value)
          ? { intValue: String(value) } : { doubleValue: value } });
      }
    }
  }
  const status = span.status;
  const code = status?.code;
  if (status !== undefined && code !== 0 && code !== 1 && code !== 2) return;
  return JSON.stringify({
    traceId: traceId.toLowerCase(),
    spanId: spanId.toLowerCase(),
    ...(parentSpanId === undefined ? {} : { parentSpanId: parentSpanId.toLowerCase() }),
    name,
    startTimeUnixNano,
    endTimeUnixNano,
    ...(status === undefined ? {} : { status: { code } }),
    ...(attributes.length ? { attributes } : {}),
  });
}

/**
 * observe never throws; flush never rejects. Invalid, excess and failed spans
 * increment dropped. At most 64 spans (including in-flight) are retained and
 * each JSON payload is at most 64 KiB. Call flush explicitly to export.
 */
export function createOtlpExporter(options: Options): {
  observe: SpanObserver;
  flush(): Promise<void>;
  readonly dropped: number;
} {
  const url = endpoint(options.url);
  const apiKey = options.apiKey;
  if (typeof apiKey !== "string" || !apiKey.trim() || /[\r\n]/.test(apiKey)) {
    throw new TypeError("Invalid OTLP authorization configuration");
  }
  const configuredTimeout = options.timeoutMs ?? 5000;
  if (!Number.isFinite(configuredTimeout) || configuredTimeout <= 0) {
    throw new TypeError("Invalid OTLP timeout");
  }
  const timeoutMs = Math.max(1, Math.min(30000, configuredTimeout));
  const send = options.fetch ?? globalThis.fetch;
  let queue: string[] = [];
  let queueBytes = PREFIX.length + SUFFIX.length;
  let pending = 0;
  let dropped = 0;
  let active: Promise<void> | undefined;

  const observe: SpanObserver = (span) => {
    try {
      if (pending >= MAX_SPANS) { dropped++; return; }
      const encoded = serialize(span);
      // All serialized fields are ASCII, so string length is UTF-8 byte size.
      const bytes = encoded === undefined ? 0 : encoded.length + (queue.length ? 1 : 0);
      if (encoded === undefined || queueBytes + bytes > MAX_BYTES) { dropped++; return; }
      queue.push(encoded);
      queueBytes += bytes;
      pending++;
    } catch {
      // Malformed JS callers (including throwing getters) cannot break a turn.
      dropped++;
    }
  };

  async function request(body: string): Promise<boolean> {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => {
        resolve(false);
        controller.abort();
      }, timeoutMs);
    });
    // Keep browser privacy hints without requiring Workers' narrower RequestInit
    // declaration to expose them; workerd ignores these browser-only fields.
    const init: RequestInit & { credentials: "omit"; referrerPolicy: "no-referrer" } = {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body,
      signal: controller.signal,
      redirect: "manual",
      credentials: "omit",
      referrerPolicy: "no-referrer",
    };
    // Both settlement paths are consumed even if a supplied fetch ignores abort
    // and rejects later. Never read/log collector bodies (including errors).
    const sent = Promise.resolve().then(() => send(url, init)).then((response) => {
      // Dispose of the body without waiting for an untrusted response stream.
      if (response.body) void response.body.cancel().catch(() => {});
      return response.ok;
    }).catch(() => false);
    try {
      return await Promise.race([sent, timeout]);
    } finally {
      clearTimeout(timer);
    }
  }

  async function drain(): Promise<void> {
    try {
      while (queue.length) {
        const batch = queue;
        queue = [];
        queueBytes = PREFIX.length + SUFFIX.length;
        try {
          if (!await request(PREFIX + batch.join(",") + SUFFIX)) dropped += batch.length;
        } catch {
          dropped += batch.length;
        } finally {
          pending -= batch.length;
        }
      }
    } finally {
      // Clear synchronously with the empty-queue check, not in a later promise
      // reaction where a new observe/flush could join an already-finished drain.
      active = undefined;
    }
  }

  function flush(): Promise<void> {
    if (active) return active;
    if (!queue.length) return Promise.resolve();
    // Defer drain so reentrant/concurrent flushes see the same promise before
    // even a synchronously executing supplied fetch can run.
    active = Promise.resolve().then(drain);
    return active;
  }

  return { observe, flush, get dropped() { return dropped; } };
}
