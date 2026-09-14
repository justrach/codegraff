"use client";
import { useCallback, useEffect, useRef, useState } from "react";
import { checkSavedCache, type CacheCheck } from "@/lib/saved-cache-check";

export default function SavedCacheCheck({ name, cwd, model, disabled, onContinue }: {
  name: string; cwd?: string; model?: string; disabled: boolean; onContinue: () => void;
}) {
  const key = JSON.stringify([name, cwd, model]);
  const pending = useRef<AbortController | null>(null);
  const [state, setState] = useState<{ key: string; result?: CacheCheck; error?: boolean; busy: boolean }>({ key, busy: true });
  const run = useCallback(async (continueAfter: boolean, previous?: CacheCheck) => {
    pending.current?.abort();
    const controller = new AbortController(); pending.current = controller;
    setState({ key, result: previous, busy: true });
    try {
      const result = await checkSavedCache(name, { cwd, model }, controller.signal);
      if (controller.signal.aborted) return;
      setState({ key, result, busy: false });
      // If the freshly read save changes the assessment, show it before proceeding.
      if (continueAfter && JSON.stringify(result) === JSON.stringify(previous)) onContinue();
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
  return <div data-saved-cache-check className="mt-3 border-t border-line pt-3">
    <p role="status" className="font-medium text-ink">{current.busy ? "Checking saved cache compatibility…" : current.error ? "Prompt cache check unavailable" : current.result?.summary}</p>
    {current.result && <details className="mt-1">
      <summary className="cursor-pointer">Check details</summary>
      <ul className="mt-1 list-disc pl-4">{current.result.reasons.map(reason => <li key={reason}>{reason}</li>)}</ul>
      <p className="mt-1">This checks saved settings only. Changes to instructions, tools, provider routing, or cache expiry cannot be verified here. Confirm reuse from provider-reported cache usage after a request.</p>
    </details>}
    {current.error && <p role="alert" className="mt-1 text-red">Could not read the save. Retry before continuing.</p>}
    <div className="mt-2 flex gap-2">
      <button type="button" disabled={disabled || current.busy} onClick={() => void run(false)} className="rounded-control px-3 py-1.5 hover:bg-hover disabled:opacity-50">Recheck cache</button>
      <button type="button" data-continue-snapshot disabled={disabled || current.busy || !current.result} onClick={() => void run(true, current.result)} className="rounded-control bg-hover-2 px-3 py-1.5 text-ink disabled:opacity-50">Continue here</button>
    </div>
  </div>;
}
