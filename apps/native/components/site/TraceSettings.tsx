"use client";
import { useEffect, useState } from "react";
import { openTraces, setTracesWanted, tracesPrefEvent, tracesWanted } from "@/lib/trace-pref";

export default function TraceSettings() {
  const [on, setOn] = useState(false);
  useEffect(() => {
    const sync = () => setOn(tracesWanted());
    sync();
    window.addEventListener(tracesPrefEvent, sync);
    window.addEventListener("storage", sync);
    return () => { window.removeEventListener(tracesPrefEvent, sync); window.removeEventListener("storage", sync); };
  }, []);
  return <fieldset className="mt-3 border-t border-line pt-3">
    <legend className="mb-1 text-xs font-medium">Run traces</legend>
    <p className="mb-3 text-xs text-ink-3">Inspect this workspace’s local <span className="font-mono">.graff/traces</span> timeline. Off until you turn it on. Stays on this machine.</p>
    <div className="flex flex-col gap-2">
      <button type="button" aria-pressed={on} onClick={() => { setTracesWanted(true); setOn(true); }}
        className={`rounded-lg border px-3 py-2 text-left text-xs focus-visible:outline-2 focus-visible:outline-accent ${on ? "border-accent bg-accent-tint" : "border-line hover:bg-hover"}`}>Show Traces in Tools</button>
      <button type="button" aria-pressed={!on} onClick={() => { setTracesWanted(false); setOn(false); }}
        className={`rounded-lg border px-3 py-2 text-left text-xs focus-visible:outline-2 focus-visible:outline-accent ${!on ? "border-accent bg-accent-tint" : "border-line hover:bg-hover"}`}>Hide</button>
    </div>
    {on && <button type="button" onClick={() => openTraces()} className="mt-2 text-xs text-accent hover:underline">Open traces…</button>}
  </fieldset>;
}
