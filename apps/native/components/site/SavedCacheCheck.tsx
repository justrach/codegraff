"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { checkSavedCache, formatSaveSize, type CacheCheck } from "@/lib/saved-cache-check";

export default function SavedCacheCheck({ name, cwd, model, disabled, onContinue, onRefresh, refreshing }: {
  name: string; cwd?: string; model?: string; disabled: boolean; onContinue: () => void;
  onRefresh?: () => void; refreshing?: boolean;
}) {
  const key = JSON.stringify([name, cwd, model]);
  const pending = useRef<AbortController | null>(null);
  const [state, setState] = useState<{ key: string; result?: CacheCheck; error?: boolean; busy: boolean; note?: string }>({ key, busy: true });
  const run = useCallback(async (continueAfter: boolean, previous?: CacheCheck) => {
    pending.current?.abort();
    const controller = new AbortController(); pending.current = controller;
    setState({ key, result: previous, busy: true, note: previous ? "Rechecking…" : undefined });
    try {
      const result = await checkSavedCache(name, { cwd, model }, controller.signal);
      if (controller.signal.aborted) return;
      const same = JSON.stringify(result) === JSON.stringify(previous);
      setState({
        key, result, busy: false,
        note: previous ? "Rechecked" : undefined,
      });
      if (continueAfter && same) onContinue();
    } catch {
      if (!controller.signal.aborted) setState({ key, busy: false, error: true });
    }
  }, [key, name, cwd, model, onContinue]);
  const runRef = useRef(run); runRef.current = run;
  useEffect(() => {
    void runRef.current(false);
    return () => pending.current?.abort();
  }, [key]);
  const current = state.key === key ? state : { key, busy: true };
  const size = formatSaveSize(current.result?.bytes);
  const line = current.busy ? (current.note ?? "Checking…")
    : current.error ? "Could not check cache"
    : current.note ?? (current.result?.status === "changed" ? "Cache at risk" : "Cache unverified");
  return <div data-saved-cache-check className="mt-2">
    <p role="status">{line}</p>
    {current.error && <p role="alert" className="mt-1 text-red">Retry before continuing.</p>}
    <div className="mt-2 flex flex-wrap gap-2">
      {onRefresh && <button type="button" data-refresh-snapshot disabled={disabled || refreshing} onClick={onRefresh} className="rounded-control px-3 py-1.5 hover:bg-hover disabled:opacity-50">{refreshing ? "Refreshing…" : "Refresh snapshot"}</button>}
      <button type="button" disabled={disabled || current.busy} onClick={() => void run(false, current.result)} className="rounded-control px-3 py-1.5 hover:bg-hover disabled:opacity-50">Recheck cache</button>
      <button type="button" data-continue-snapshot disabled={disabled || current.busy || !current.result} onClick={() => void run(true, current.result)} className="rounded-control bg-hover-2 px-3 py-1.5 text-ink disabled:opacity-50">
        {size ? `Continue here · ${size}` : "Continue here"}
      </button>
    </div>
  </div>;
}
