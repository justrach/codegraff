"use client";
import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { eventLabel, formatDuration, type TraceEvent, type TraceSummary } from "@/lib/run-traces";
import { tracesOpenEvent } from "@/lib/trace-pref";
import { listTraces, readTrace, type TraceListItem } from "@/lib/traces";

function workspaceRoot(): string | undefined {
  return document.querySelector<HTMLElement>("[data-workspace-root]")?.dataset.workspaceRoot || undefined;
}

function EventRow({ event }: { event: TraceEvent }) {
  return <li className={`flex items-baseline gap-2 py-1 text-[12.5px] ${event.is_error ? "text-red" : "text-ink-2"}`}>
    <span className="w-16 shrink-0 tabular-nums text-ink-3">{formatDuration(event.t)}</span>
    <span className="min-w-0 flex-1 truncate">{eventLabel(event)}{event.from_sub ? " · worker" : ""}</span>
    {event.ms !== undefined && <span className="shrink-0 tabular-nums text-ink-3">{formatDuration(event.ms)}</span>}
  </li>;
}

export default function TracesPane() {
  const [open, setOpen] = useState(false);
  const [root, setRoot] = useState<string | undefined>();
  const [rows, setRows] = useState<TraceListItem[] | null>(null);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const [detail, setDetail] = useState<{ summary: TraceSummary; events: TraceEvent[]; truncated: boolean } | null>(null);
  const [loading, setLoading] = useState("");

  useEffect(() => {
    const openPane = () => { setRoot(workspaceRoot()); setOpen(true); };
    window.addEventListener(tracesOpenEvent, openPane);
    return () => window.removeEventListener(tracesOpenEvent, openPane);
  }, []);

  useEffect(() => {
    if (!open) return;
    const keys = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); setOpen(false); } };
    document.addEventListener("keydown", keys);
    return () => document.removeEventListener("keydown", keys);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    let alive = true;
    setRows(null); setError(""); setSelected(null); setDetail(null); setLoading("Reading traces…");
    void listTraces(root).then(list => { if (alive) { setRows(list); setError(""); } })
      .catch(e => { if (alive) setError(e instanceof Error ? e.message : "Traces unavailable"); })
      .finally(() => { if (alive) setLoading(""); });
    return () => { alive = false; };
  }, [open, root]);

  useEffect(() => {
    if (!open || !selected) return;
    let alive = true;
    setDetail(null); setLoading("Reading run…");
    void readTrace(selected, root).then(next => { if (alive) { setDetail(next); setError(""); } })
      .catch(e => { if (alive) setError(e instanceof Error ? e.message : "Trace unavailable"); })
      .finally(() => { if (alive) setLoading(""); });
    return () => { alive = false; };
  }, [open, selected, root]);

  if (!open) return null;
  return createPortal(
    <div className="fixed inset-0 z-[180] flex justify-end bg-black/20 p-3" onPointerDown={event => { if (event.target === event.currentTarget) setOpen(false); }}>
      <aside role="dialog" aria-label="Run traces" aria-modal="true" className="flex h-full w-[min(440px,100%)] flex-col overflow-hidden rounded-window border border-line bg-page text-ink shadow-overlay">
        <header className="flex items-center gap-3 border-b border-line p-4">
          <div className="min-w-0 flex-1">
            <strong>Traces</strong>
            <p className="mt-1 text-xs text-ink-3">This workspace’s local run timeline. Prompt text is not shown.</p>
          </div>
          <button type="button" onClick={() => setOpen(false)} aria-label="Close traces" className="rounded px-2 py-1 hover:bg-hover">×</button>
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto p-4">
          {loading && <p role="status" className="text-sm text-ink-3">{loading}</p>}
          {error && <p role="alert" className="text-sm text-red">{error}</p>}
          {!selected && rows && !rows.length && !loading && <p className="text-sm text-ink-2">No traces in this workspace yet. Run a turn, then reopen.</p>}
          {!selected && rows && !!rows.length && <ul className="space-y-2">{rows.map(row =>
            <li key={row.id}>
              <button type="button" onClick={() => setSelected(row.id)} className="w-full rounded-xl border border-line bg-surface px-3 py-2 text-left hover:bg-hover">
                <div className="flex items-center gap-2 text-[12.5px]">
                  <span className="min-w-0 flex-1 truncate font-mono text-ink">{row.id}</span>
                  <span className="shrink-0 tabular-nums text-ink-3">{formatDuration(row.durationMs)}</span>
                </div>
                <p className="mt-1 text-[11px] text-ink-3">{row.events} events{row.errors ? ` · ${row.errors} errors` : ""}{row.models[0] ? ` · ${row.models[0]}` : ""}</p>
              </button>
            </li>
          )}</ul>}
          {selected && <div className="space-y-3">
            <button type="button" className="text-xs hover:underline" onClick={() => { setSelected(null); setDetail(null); }}>← All traces</button>
            {detail && <>
              <p className="text-xs text-ink-3 font-mono break-all">{detail.summary.id}</p>
              <p className="text-xs text-ink-3">{detail.summary.events} events · {formatDuration(detail.summary.durationMs)}{detail.summary.tools.length ? ` · ${detail.summary.tools.slice(0, 4).join(", ")}` : ""}{detail.truncated ? " · truncated" : ""}</p>
              <ol className="divide-y divide-line">{detail.events.map((event, i) => <EventRow key={`${event.t}:${event.ev}:${i}`} event={event} />)}</ol>
            </>}
          </div>}
        </div>
      </aside>
    </div>,
    document.body,
  );
}
