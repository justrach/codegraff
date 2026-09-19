import type { TraceEvent, TraceSummary } from "./run-traces";

function query(params: Record<string, string | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) q.set(k, v);
  const s = q.toString();
  return s ? `?${s}` : "";
}

export type TraceListItem = TraceSummary & { mtime: number; bytes: number; truncated: boolean };

export async function listTraces(root?: string): Promise<TraceListItem[]> {
  const res = await fetch(`/api/traces${query({ root })}`, { cache: "no-store" });
  const body = await res.json() as { traces?: TraceListItem[]; error?: string };
  if (!res.ok) throw new Error(body.error ?? `traces ${res.status}`);
  return body.traces ?? [];
}

export async function readTrace(id: string, root?: string): Promise<{ summary: TraceSummary; events: TraceEvent[]; truncated: boolean }> {
  const res = await fetch(`/api/traces${query({ root, id })}`, { cache: "no-store" });
  const body = await res.json() as { summary?: TraceSummary; events?: TraceEvent[]; truncated?: boolean; error?: string };
  if (!res.ok) throw new Error(body.error ?? `traces ${res.status}`);
  return { summary: body.summary ?? { id, events: 0, errors: 0, durationMs: 0, models: [], tools: [] }, events: body.events ?? [], truncated: !!body.truncated };
}
