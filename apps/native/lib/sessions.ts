import {
  chipFor,
  emptyTurn,
  firstLine,
  iconFor,
  summarizeInput,
  type AssistantTurn,
  type TodoItem,
  type ToolRow,
} from "./graff-events.ts";

/** A conversation graff autosaved under `.graff/sessions/<name>.session.json`. */
export type StoredSession = {
  name: string;
  title: string | null;
  updatedMs: number;
  model: string | null;
  provider: string | null;
  size: number;
  workspace?: string | null;
  /** Set when the save is not in the current cwd (ADR 0059). */
  origin?: string | null;
  local?: boolean;
};

export type SessionPage = {
  cwd?: string;
  sessions: StoredSession[];
  nextCursor: string | null;
  total: number;
};

export type SessionScope = "all" | "local" | "elsewhere";

export type TranscriptMsg =
  | { role: "user"; text: string }
  | { role: "assistant"; turn: AssistantTurn };

const BASE = "/api/sessions";

export async function listSessionsPage(opts: {
  limit?: number;
  cursor?: string | null;
  q?: string;
  scope?: SessionScope;
} = {}): Promise<SessionPage> {
  const params = new URLSearchParams();
  if (opts.limit) params.set("limit", String(opts.limit));
  if (opts.cursor) params.set("cursor", opts.cursor);
  if (opts.q?.trim()) params.set("q", opts.q.trim());
  if (opts.scope && opts.scope !== "all") params.set("scope", opts.scope);
  const qs = params.toString();
  const res = await fetch(qs ? `${BASE}?${qs}` : BASE, { cache: "no-store" });
  if (!res.ok) throw new Error(`sessions → ${res.status}`);
  const body = (await res.json()) as Partial<SessionPage>;
  return {
    cwd: body.cwd,
    sessions: body.sessions ?? [],
    nextCursor: body.nextCursor ?? null,
    total: typeof body.total === "number" ? body.total : (body.sessions ?? []).length,
  };
}

export async function listSessions(): Promise<StoredSession[]> {
  const page = await listSessionsPage();
  return page.sessions;
}

export async function loadSession(name: string): Promise<{ meta: StoredSession; messages: TranscriptMsg[] }> {
  const res = await fetch(`${BASE}?name=${encodeURIComponent(name)}`, { cache: "no-store" });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`session ${name} → ${res.status}: ${detail.slice(0, 200)}`);
  }
  const body = (await res.json()) as StoredSession & { messages?: unknown[] };
  const { messages, ...meta } = body;
  return { meta, messages: transcriptFromMessages(messages ?? [], meta.model ?? undefined) };
}

/** Sidebar bucket for a session's last activity, newest buckets first. */
export function dateGroup(ms: number, now = Date.now()): string {
  const today = new Date(now);
  const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  const day = 86_400_000;
  if (ms >= startOfToday) return "Today";
  if (ms >= startOfToday - day) return "Yesterday";
  if (ms >= startOfToday - 7 * day) return "Previous 7 days";
  if (ms >= startOfToday - 30 * day) return "Previous 30 days";
  return new Date(ms).toLocaleString(undefined, { month: "long", year: "numeric" });
}

export function relativeTime(ms: number, now = Date.now()): string {
  const delta = Math.max(0, now - ms);
  const min = Math.round(delta / 60_000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hours = Math.round(min / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}

export function sessionHint(s: StoredSession, now = Date.now()): string {
  const where = s.local === false ? (s.origin ?? "elsewhere") : null;
  return [where, s.model, relativeTime(s.updatedMs, now)].filter(Boolean).join(" · ");
}

export function toSidebarRecent(s: StoredSession, now = Date.now()): {
  id: string;
  label: string;
  group: string;
  hint: string;
} {
  return {
    id: s.name,
    label: s.title ?? s.name,
    group: dateGroup(s.updatedMs, now),
    hint: sessionHint(s, now),
  };
}

/** Consecutive rows that share a date bucket, newest buckets first. */
export function groupSessions(rows: StoredSession[], now = Date.now()): { group: string; items: StoredSession[] }[] {
  const out: { group: string; items: StoredSession[] }[] = [];
  for (const row of rows) {
    const group = dateGroup(row.updatedMs, now);
    const last = out[out.length - 1];
    if (last && last.group === group) last.items.push(row);
    else out.push({ group, items: [row] });
  }
  return out;
}

type RawCall = { id?: unknown; function?: { name?: unknown; arguments?: unknown } };
type RawMsg = { role?: unknown; content?: unknown; tool_calls?: unknown; tool_call_id?: unknown };

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (part && typeof part === "object" && typeof (part as { text?: unknown }).text === "string" ? (part as { text: string }).text : ""))
    .filter(Boolean)
    .join("\n");
}

function humanize(id: string): string {
  const words = id.replace(/[_-]+/g, " ").trim();
  return words ? words[0].toUpperCase() + words.slice(1) : id;
}

/** `mcp__codedbpro__faster_search` → "Faster search"; `write_file` → "Write file". */
function labelFor(name: string): string {
  if (name.startsWith("mcp__")) {
    const rest = name.slice(5);
    const split = rest.indexOf("__");
    return humanize(split < 0 ? rest : rest.slice(split + 2));
  }
  return humanize(name);
}

function todosOf(input: Record<string, unknown>): TodoItem[] {
  const raw = input.todos;
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item, i) => {
    if (!item || typeof item !== "object") return [];
    const rec = item as Record<string, unknown>;
    const content = typeof rec.content === "string" ? rec.content : "";
    if (!content) return [];
    const status = rec.status === "completed" || rec.status === "in_progress" ? rec.status : "pending";
    return [{ id: typeof rec.id === "string" ? rec.id : `todo-${i}`, content, status }];
  });
}

function appendText(turn: AssistantTurn, text: string): void {
  const t = text.trim();
  if (!t) return;
  turn.text = turn.text ? `${turn.text}\n\n${t}` : t;
}

/**
 * Rebuild the harness's turn shapes from a saved session's provider-native
 * message array (user / assistant+tool_calls / tool). Consecutive assistant
 * and tool messages fold into one turn until the next user message, the way
 * the live ACP stream renders a turn; `attempt_completion` is the engine's
 * final-answer tool, so its `result` becomes prose instead of a tool row.
 */
export function transcriptFromMessages(raw: unknown[], model?: string): TranscriptMsg[] {
  const out: TranscriptMsg[] = [];
  let turn: AssistantTurn | null = null;
  const flush = () => {
    if (turn) out.push({ role: "assistant", turn: { ...turn, status: "done" } });
    turn = null;
  };
  const current = (): AssistantTurn => (turn ??= { ...emptyTurn(), model, status: "done" });

  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const msg = item as RawMsg;
    if (msg.role === "user") {
      const text = textOf(msg.content).trim();
      if (!text) continue;
      flush();
      out.push({ role: "user", text });
      continue;
    }
    if (msg.role === "assistant") {
      const t = current();
      appendText(t, textOf(msg.content));
      const calls = Array.isArray(msg.tool_calls) ? (msg.tool_calls as RawCall[]) : [];
      for (const call of calls) {
        const name = typeof call.function?.name === "string" ? call.function.name : "tool";
        let input: Record<string, unknown> = {};
        try {
          const parsed: unknown = JSON.parse(typeof call.function?.arguments === "string" ? call.function.arguments : "{}");
          if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) input = parsed as Record<string, unknown>;
        } catch {
          // malformed arguments still get a row, just without detail
        }
        if (name === "attempt_completion") {
          if (typeof input.result === "string") appendText(t, input.result);
          continue;
        }
        if (name === "todo_write") {
          const todos = todosOf(input);
          if (todos.length) t.todos = todos;
        }
        const label = labelFor(name);
        const chip = chipFor(name, input);
        const path = typeof input.path === "string" ? input.path : typeof input.file === "string" ? input.file : undefined;
        const row: ToolRow = {
          id: typeof call.id === "string" ? call.id : `${name}:${t.tools.length}`,
          name: label,
          icon: iconFor(name),
          chip: chip === name ? "" : chip,
          status: "ok",
          detail: summarizeInput(name, input),
          path,
        };
        t.tools = [...t.tools, row];
      }
      continue;
    }
    if (msg.role === "tool") {
      const t = current();
      const idx = t.tools.findIndex((row) => row.id === msg.tool_call_id);
      if (idx < 0) continue;
      const text = textOf(msg.content).trim();
      const failed = /^(error|failed|denied)\b/i.test(text);
      t.tools = t.tools.map((row, i) =>
        i === idx
          ? { ...row, status: failed ? "error" : row.status, detail: text ? [...row.detail, { text: firstLine(text) }] : row.detail }
          : row,
      );
    }
  }
  flush();
  return out;
}
