"use client";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { desktop, type LinkDestination } from "@/lib/desktop";

export default function DesktopSettings() {
  const [available, setAvailable] = useState(false);
  const [open, setOpen] = useState(false);
  const [destination, setDestination] = useState<LinkDestination | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => setAvailable(!!desktop()?.linkSettings), []);
  useEffect(() => {
    if (!open) return;
    let alive = true;
    setDestination(null); setError("");
    void desktop()!.linkSettings!("load").then(value => { if (alive) setDestination(value); })
      .catch(() => { if (alive) setError("Could not load link settings. Close Settings and try again."); });
    panel.current?.querySelector<HTMLButtonElement>("button")?.focus();
    const keys = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.stopPropagation(); setOpen(false); trigger.current?.focus(); }
      if (event.key === "Tab") {
        const buttons = Array.from(panel.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? []);
        if (!buttons.length) return;
        event.preventDefault();
        const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
        buttons[(index + (event.shiftKey ? buttons.length - 1 : 1)) % buttons.length]?.focus();
      }
    };
    document.addEventListener("keydown", keys);
    return () => { alive = false; document.removeEventListener("keydown", keys); };
  }, [open]);
  const choose = async (value: LinkDestination) => {
    setSaving(true); setError("");
    try { setDestination(await desktop()!.linkSettings!("save", value)); }
    catch { setError("Could not save link settings. Try again."); }
    finally { setSaving(false); }
  };
  if (!available) return null;
  return <>
    <button ref={trigger} aria-label="Settings" title="Settings" aria-haspopup="dialog" aria-expanded={open}
      onClick={() => setOpen(value => !value)} className="flex size-8 shrink-0 items-center justify-center rounded-lg text-ink-3 hover:bg-hover hover:text-ink">
      <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3h6l1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3Z"/><circle cx="12" cy="12" r="3"/></svg>
    </button>
    {open && createPortal(<div className="fixed inset-0 z-[200] flex items-center justify-center bg-black/20 p-4" onPointerDown={event => {
      if (event.target === event.currentTarget) { setOpen(false); trigger.current?.focus(); }
    }}>
      <div ref={panel} role="dialog" aria-label="Settings" aria-modal="true" className="w-[380px] max-w-full rounded-xl border border-line bg-surface p-4 shadow-overlay">
        <div className="mb-4 flex items-center justify-between"><strong className="text-sm font-medium">Settings</strong><button aria-label="Close settings" onClick={() => { setOpen(false); trigger.current?.focus(); }} className="rounded px-1.5 text-ink-3 hover:bg-hover">×</button></div>
        <fieldset disabled={destination === null || saving}>
          <legend className="mb-1 text-xs font-medium">Open web links in</legend>
          <p className="mb-3 text-xs text-ink-3">Choose where links from conversations open. Graff keeps pages beside your chat.</p>
          <div className="flex flex-col gap-2">{([['system', 'System default browser'], ['graff', 'Graff built-in Browser']] as const).map(([value, label]) =>
            <button key={value} aria-pressed={destination === value} onClick={() => void choose(value)} className={`rounded-lg border px-3 py-2 text-left text-xs focus-visible:outline-2 focus-visible:outline-accent disabled:opacity-50 ${destination === value ? "border-accent bg-accent-tint" : "border-line hover:bg-hover"}`}>{label}</button>
          )}</div>
        </fieldset>
        {saving && <p role="status" className="mt-3 text-xs text-ink-3">Saving…</p>}
        {error && <p role="alert" className="mt-3 text-xs text-red">{error}</p>}
      </div>
    </div>, document.body)}
  </>;
}
