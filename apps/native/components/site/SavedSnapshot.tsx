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
  return <section data-saved-snapshot data-session-snapshot aria-label="Saved conversation snapshot" className="border-t border-line px-1 py-2 text-[12px] text-ink-2">
    <p role="status" className="font-medium text-ink">Saved conversation · Live REPL status unknown</p>
    {error && <p role="alert" className="mt-1 text-red">Could not refresh.</p>}
    <SavedCacheCheck name={name} cwd={cwd} model={model} disabled={refreshing} onContinue={onContinue} onRefresh={() => void refresh()} refreshing={refreshing} />
  </section>;
}
