import { parseRpcLine, type AcpUpdate, type JsonRpcLine } from "./acp";

const BASE = "/api/acp";

export type Health = { ok: boolean; detail?: string; cwd?: string };

async function* ndjson(res: Response): AsyncGenerator<JsonRpcLine> {
  const body = res.body;
  if (!body) throw new Error("ACP bridge had no body");
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
        const ev = parseRpcLine(line);
        if (ev) yield ev;
      }
    }
    const tail = parseRpcLine(buf);
    if (tail) yield tail;
  } finally {
    await reader.cancel().catch(() => {});
  }
}

async function rpc(method: string, params?: unknown, stream = false): Promise<Response> {
  const res = await fetch(BASE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ method, params, stream }),
    cache: "no-store",
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`ACP ${method} → ${res.status}: ${detail.slice(0, 240)}`);
  }
  return res;
}

export async function checkHealth(): Promise<Health> {
  try {
    const res = await fetch(BASE, { method: "GET", cache: "no-store" });
    if (!res.ok) return { ok: false, detail: `acp ${res.status}` };
    return (await res.json()) as Health;
  } catch (err) {
    return { ok: false, detail: err instanceof Error ? err.message : String(err) };
  }
}

export async function ensureSession(model?: string, reset = false): Promise<string> {
  const res = await rpc("bootstrap", { model, reset });
  const body = (await res.json()) as { sessionId?: string; error?: string };
  if (!body.sessionId) throw new Error(body.error ?? "ACP session/new failed");
  return body.sessionId;
}

export async function* prompt(
  sessionId: string,
  text: string,
): AsyncGenerator<AcpUpdate> {
  const res = await rpc("session/prompt", {
    sessionId,
    prompt: [{ type: "text", text }],
  }, true);
  let terminal = false;
  for await (const line of ndjson(res)) {
    if ("method" in line && line.method === "session/update") {
      yield line.params.update;
      continue;
    }
    if ("error" in line && line.error) {
      throw new Error(line.error.message);
    }
    if ("result" in line) {
      terminal = true;
      break;
    }
  }
  if (!terminal) throw new Error("ACP stream ended before session/prompt returned");
}

export async function cancel(sessionId: string): Promise<void> {
  await fetch(BASE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ method: "session/cancel", params: { sessionId } }),
  }).catch(() => {});
}

export const STARTER_PROMPTS = [
  { id: "files", label: "What files are here?", prompt: "What files are in this workspace? Be brief." },
  { id: "readme", label: "Summarize README.md", prompt: "Read README.md and summarize it in a short paragraph." },
  { id: "review", label: "Review the last commit", prompt: "Review HEAD against the previous commit. Stay read-only." },
  { id: "todos", label: "What's on the checklist?", prompt: "Read the current todo list and tell me what's open." },
] as const;

export type ModelChoice = {
  key: string;
  name: string;
  tag?: string;
  provider?: string;
  context?: number;
  cost?: string;
  current?: boolean;
};

type GraffModelsResult = {
  models?: {
    name: string;
    provider: string;
    context: number;
    authenticated: boolean;
    cost: string;
    current: boolean;
  }[];
  current?: { model: string; provider: string };
};

/** The models THIS install can reach: `graff/models` filtered to providers
 * with live credentials, already in the agent's election order. The same
 * model name can be served by several providers; the highest-ranked seat
 * wins its row (spawn-by-name resolves through graff's own routing anyway). */
export async function fetchModels(): Promise<{ models: ModelChoice[]; current: string | null }> {
  const res = await rpc("graff/models");
  const body = (await res.json()) as { result?: GraffModelsResult; error?: string };
  if (!body.result) throw new Error(body.error ?? "graff/models failed");
  const seen = new Set<string>();
  const models: ModelChoice[] = [];
  for (const m of body.result.models ?? []) {
    if (!m.authenticated || seen.has(m.name)) continue;
    seen.add(m.name);
    models.push({
      key: m.name,
      name: m.name,
      tag: m.cost === "plan" || m.cost === "credits" ? `${m.provider} · ${m.cost}` : m.provider,
      provider: m.provider,
      context: m.context,
      cost: m.cost,
      current: m.current,
    });
  }
  return { models, current: body.result.current?.model ?? null };
}

/** Fallback until `graff/models` answers (or when nothing is authenticated). */
export const MODELS: ModelChoice[] = [
  { key: "gpt-5.5", name: "GPT-5.5", tag: "OpenAI" },
  { key: "claude-opus-4-8", name: "Opus 4.8", tag: "Anthropic" },
  { key: "codex", name: "Codex", tag: "ChatGPT" },
  { key: "grok-4.6", name: "Grok 4.6", tag: "xAI" },
  { key: "kimi-k2.6", name: "Kimi K2.6", tag: "Moonshot" },
];
