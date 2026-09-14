"use client";
import { useEffect, useRef, useState } from "react";
import SavedCacheCheck from "./SavedCacheCheck";
import { loadSession } from "@/lib/sessions";

export default function SavedSnapshot({ name, cwd, model, onRefresh, onContinue }: {
  name: string; cwd?: string; model?: string;
  onRefresh: (loaded: Awaited<ReturnType<typeof loadSession>>) => void;
  onContinue: () => void;
}) {
  const pending = useRef<AbortController | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState(false);
  useEffect(() => () => { pending.current?.abort(); }, [name, cwd]);
  const refresh = async () => {
    pending.current?.abort();
    const controller = new AbortController(); pending.current = controller;
    setRefreshing(true); setError(false);
    try {
      const loaded = await loadSession(name, cwd, controller.signal);
      if (!controller.signal.aborted) onRefresh(loaded);
    } catch {
      if (!controller.signal.aborted) setError(true);
    } finally {
      if (!controller.signal.aborted) setRefreshing(false);
    }
  };
  return <section data-saved-snapshot aria-label="Saved conversation snapshot" className="rounded-[12px] border border-line bg-surface p-4 text-[13px] text-ink-2">
    <p role="status" className="font-medium text-ink">Saved snapshot · Live status unknown</p>
    <p className="mt-1">Work may still be running in another window. Refresh to read the latest save.</p>
    <p className="mt-1">Stop work in the other window before choosing Continue here.</p>
    {error && <p role="alert" className="mt-2 text-red">Could not refresh the snapshot. Try again.</p>}
    <div className="mt-3 flex flex-wrap gap-2">
      <button type="button" data-refresh-snapshot disabled={refreshing} onClick={() => void refresh()} className="rounded-control px-3 py-1.5 hover:bg-hover disabled:opacity-50">{refreshing ? "Refreshing…" : "Refresh snapshot"}</button>
    </div>
    <SavedCacheCheck name={name} cwd={cwd} model={model} disabled={refreshing} onContinue={onContinue} />
  </section>;
}
