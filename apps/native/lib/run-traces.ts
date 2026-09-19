/** Operational `.graff/traces/<run>.jsonl` → a readable timeline.
 * Only allowlisted fields: no prompt text, no paths, no raw detail. */

export type TraceEvent = {
  t: number;
  ev: string;
  name?: string;
  model?: string;
  ms?: number;
  is_error?: boolean;
  agent?: string;
  from_sub?: boolean;
  turn?: number;
};

export type TraceSummary = {
  id: string;
  events: number;
  errors: number;
  durationMs: number;
  models: string[];
  tools: string[];
};

const MAX_EVENTS = 2000;
const SKIP = new Set(["prompt"]);
export const TRACE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;

export function isTraceId(id: string): boolean {
  return TRACE_ID.test(id);
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function text(value: unknown, max = 64): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
}

export function parseTraceLine(line: string): TraceEvent | null {
  let raw: unknown;
  try { raw = JSON.parse(line); } catch { return null; }
  if (!raw || typeof raw !== "object") return null;
  const rec = raw as Record<string, unknown>;
  const ev = text(rec.ev) ?? text(rec.kind);
  const t = num(rec.t);
  if (!ev || t === undefined || SKIP.has(ev)) return null;
  return {
    t,
    ev,
    name: text(rec.name),
    model: text(rec.model, 80),
    ms: num(rec.ms),
    is_error: rec.is_error === true,
    agent: text(rec.agent, 32),
    from_sub: rec.from_sub === true ? true : undefined,
    turn: num(rec.turn),
  };
}

export function summarizeTrace(id: string, text: string): { summary: TraceSummary; events: TraceEvent[] } {
  const events: TraceEvent[] = [];
  const models = new Set<string>();
  const tools = new Set<string>();
  let errors = 0;
  let durationMs = 0;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const event = parseTraceLine(line);
    if (!event) continue;
    if (events.length < MAX_EVENTS) events.push(event);
    durationMs = Math.max(durationMs, event.t);
    if (event.model) models.add(event.model);
    if (event.name && event.ev === "tool") tools.add(event.name);
    if (event.is_error) errors += 1;
  }
  return {
    summary: { id, events: events.length, errors, durationMs, models: [...models], tools: [...tools] },
    events,
  };
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)}s`;
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.round((ms % 60_000) / 1000);
  return seconds ? `${minutes}m ${seconds}s` : `${minutes}m`;
}

export function eventLabel(event: TraceEvent): string {
  if (event.ev === "tool") return event.name ?? "tool";
  if (event.ev === "api") return event.model ? `api · ${event.model}` : "api";
  if (event.ev === "first_token") return event.model ? `first token · ${event.model}` : "first token";
  return event.ev.replaceAll("_", " ");
}
