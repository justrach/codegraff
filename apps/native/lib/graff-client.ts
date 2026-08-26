import { parseEventLine, type GraffEvent } from "./graff-events";

/** Browser client for `graff serve` via the Next.js `/api/graff` proxy.
 *  Same request/event contract as `sdk/ts/remote.ts` (one POST = one
 *  protocol request, streamed back as NDJSON until the terminal event). */

const BASE = "/api/graff";

export type SessionInfo = {
  session_id: string;
  resumed: boolean;
  last_seq: number;
};

export type Health = {
  ok: boolean;
  detail?: string;
};

async function* ndjson(res: Response): AsyncGenerator<GraffEvent> {
  const body = res.body;
  if (!body) throw new Error("bridge response had no body");
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        const ev = parseEventLine(line);
        if (ev) yield ev;
      }
    }
    const tail = parseEventLine(buf);
    if (tail) yield tail;
  } finally {
    await reader.cancel().catch(() => {});
  }
}

async function req(method: string, path: string, body?: unknown): Promise<Response> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`graff ${method} ${path} → ${res.status}: ${detail.slice(0, 240)}`);
  }
  return res;
}

export async function checkHealth(): Promise<Health> {
  try {
    const res = await fetch(`${BASE}/healthz`, { cache: "no-store" });
    if (!res.ok) return { ok: false, detail: `healthz ${res.status}` };
    return { ok: true };
  } catch (err) {
    return { ok: false, detail: err instanceof Error ? err.message : String(err) };
  }
}

export async function createSession(opts?: {
  session?: string;
  model?: string;
  yolo?: boolean;
}): Promise<SessionInfo> {
  const body: Record<string, unknown> = {};
  if (opts?.session) body.session = opts.session;
  if (opts?.model) body.model = opts.model;
  if (opts?.yolo !== undefined) body.yolo = opts.yolo;
  const res = await req("POST", "/v1/sessions", body);
  return (await res.json()) as SessionInfo;
}

export async function* chat(
  sessionId: string,
  prompt: string,
  signal?: AbortSignal,
): AsyncGenerator<GraffEvent> {
  const res = await req("POST", `/v1/sessions/${encodeURIComponent(sessionId)}`, {
    type: "user",
    text: prompt,
  });
  if (signal?.aborted) {
    await cancel(sessionId);
    return;
  }
  let terminal = false;
  for await (const ev of ndjson(res)) {
    yield ev;
    if (ev.type === "turn" || ev.type === "error") {
      terminal = true;
      break;
    }
  }
  if (!terminal) throw new Error("bridge stream ended mid-turn (session process died?)");
}

export async function answer(
  sessionId: string,
  input: { text: string; callId?: string; cancelled?: boolean },
): Promise<void> {
  const res = await req("POST", `/v1/sessions/${encodeURIComponent(sessionId)}`, {
    type: "answer",
    text: input.text,
    cancelled: input.cancelled ?? false,
    call_id: input.callId,
  });
  await res.text();
}

export async function cancel(sessionId: string): Promise<void> {
  const res = await fetch(`${BASE}/v1/sessions/${encodeURIComponent(sessionId)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "cancel" }),
  }).catch(() => null);
  if (res) await res.text().catch(() => {});
}

export async function setModel(sessionId: string, model: string, provider?: string): Promise<void> {
  const payload: Record<string, unknown> = { type: "set_model", model };
  if (provider) payload.provider = provider;
  const res = await req("POST", `/v1/sessions/${encodeURIComponent(sessionId)}`, payload);
  for await (const ev of ndjson(res)) {
    if (ev.type === "error") throw new Error(String((ev as { message?: string }).message ?? "set_model failed"));
    if (ev.type === "model") return;
  }
}

export async function closeSession(sessionId: string): Promise<void> {
  await fetch(`${BASE}/v1/sessions/${encodeURIComponent(sessionId)}`, { method: "DELETE" }).catch(
    () => {},
  );
}

export const STARTER_PROMPTS = [
  { id: "files", label: "What files are here?", prompt: "What files are in this workspace? Be brief." },
  { id: "readme", label: "Summarize README.md", prompt: "Read README.md and summarize it in a short paragraph." },
  { id: "review", label: "Review the last commit", prompt: "Review HEAD against the previous commit. Stay read-only." },
  { id: "todos", label: "What's on the checklist?", prompt: "Read the current todo list and tell me what's open." },
] as const;

export const MODELS = [
  { key: "gpt-5.5", name: "GPT-5.5", tag: "OpenAI" },
  { key: "claude-opus-4-8", name: "Opus 4.8", tag: "Anthropic" },
  { key: "codex", name: "Codex", tag: "ChatGPT" },
  { key: "grok-4.6", name: "Grok 4.6", tag: "xAI" },
  { key: "kimi-k2.6", name: "Kimi K2.6", tag: "Moonshot" },
];
