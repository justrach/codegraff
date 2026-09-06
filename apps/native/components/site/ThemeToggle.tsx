"use client";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import CustomThemes from "./CustomThemes";
import { appearanceEvent, appearanceKey, applyAppearance, readAppearance, type Appearance } from "@/lib/appearance";

const themes = [
  { id: "codegraff", name: "CodeGraff", detail: "Official · Japanese palette", bg: "#f6eedf", surface: "#fffaf0", ink: "#1b1714", accent: "#2654d9" },
  { id: "light", name: "White", detail: "Light and minimal", bg: "#fafafa", surface: "#ffffff", ink: "#25272b", accent: "#3785fa" },
  { id: "dark", name: "Black", detail: "Quiet charcoal", bg: "#17181b", surface: "#24262a", ink: "#f4f4f5", accent: "#5b9cf7" },
  { id: "website", name: "Website", detail: "CodeGraff emerald", bg: "#fafaf8", surface: "#ffffff", ink: "#18231e", accent: "#059669" },
] as const;

export function ThemeToggle() {
  const [theme, setTheme] = useState<Appearance>("dark");
  const [position, setPosition] = useState<{ top: number; right: number } | null>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const sync = () => setTheme(readAppearance());
    sync(); window.addEventListener(appearanceEvent, sync); window.addEventListener("storage", sync);
    return () => { window.removeEventListener(appearanceEvent, sync); window.removeEventListener("storage", sync); };
  }, []);
  useEffect(() => {
    if (!position) return;
    panel.current?.querySelector<HTMLButtonElement>('[aria-pressed="true"]')?.focus();
    const outside = (event: PointerEvent) => { if (!panel.current?.contains(event.target as Node) && !trigger.current?.contains(event.target as Node)) setPosition(null); };
    const keys = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.stopPropagation(); setPosition(null); trigger.current?.focus(); }
      if (event.key === "Tab") {
        const buttons = Array.from(panel.current?.querySelectorAll<HTMLButtonElement>("button") ?? []);
        const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
        if (index >= 0) { event.preventDefault(); buttons[(index + (event.shiftKey ? buttons.length - 1 : 1)) % buttons.length]?.focus(); }
      }
    };
    const close = () => setPosition(null);
    document.addEventListener("pointerdown", outside); document.addEventListener("keydown", keys);
    window.addEventListener("resize", close);
    return () => { document.removeEventListener("pointerdown", outside); document.removeEventListener("keydown", keys); window.removeEventListener("resize", close); };
  }, [position]);
  const choose = (next: Appearance) => {
    document.documentElement.classList.add("theme-switching");
    applyAppearance(next); setTheme(next);
    try { localStorage.setItem(appearanceKey, next); } catch {}
    window.dispatchEvent(new Event(appearanceEvent));
    requestAnimationFrame(() => requestAnimationFrame(() => document.documentElement.classList.remove("theme-switching")));
  };
  return <>
    <button ref={trigger} aria-label="Appearance" title="Appearance" aria-haspopup="dialog" aria-expanded={!!position} onClick={() => {
      const rect = trigger.current!.getBoundingClientRect();
      setPosition(position ? null : { top: Math.max(48, Math.min(rect.bottom + 8, window.innerHeight - 420)), right: Math.max(8, window.innerWidth - rect.right) });
    }} className="flex size-8 shrink-0 items-center justify-center rounded-lg text-ink-3 hover:bg-hover hover:text-ink">
      <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><circle cx="12" cy="12" r="8" /><path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" stroke="none" /></svg>
    </button>
    {position && createPortal(<div ref={panel} role="dialog" aria-label="Appearance" aria-modal="true" className="fixed z-[200] w-[310px] max-w-[calc(100vw-16px)] overflow-y-auto rounded-xl border border-line bg-surface p-3 shadow-overlay" style={{ ...position, maxHeight: `calc(100dvh - ${position.top + 12}px)` }}>
      <div className="mb-3 flex items-center justify-between"><strong className="text-xs font-medium">Appearance</strong><button aria-label="Close appearance" onClick={() => { setPosition(null); trigger.current?.focus(); }} className="rounded px-1.5 text-ink-3 hover:bg-hover">×</button></div>
      <div className="grid grid-cols-2 gap-2">{themes.map(option => <button key={option.id} aria-pressed={theme === option.id} onClick={() => choose(option.id)} className={`rounded-lg border p-1.5 text-left focus-visible:outline-2 focus-visible:outline-accent ${theme === option.id ? "border-accent bg-accent-tint" : "border-line hover:bg-hover"}`}>
        <span aria-hidden="true" className="mb-2 flex h-14 gap-1 overflow-hidden rounded p-1.5" style={{ background: option.bg }}><span className="w-3 rounded-sm" style={{ background: option.id === "codegraff" ? "#d45a43" : option.accent, opacity: .35 }} /><span className="flex flex-1 flex-col gap-1 rounded p-1" style={{ background: option.surface }}><span className="h-1 w-5 rounded" style={{ background: option.ink, opacity: .45 }} /><span className="h-1 w-8 rounded" style={{ background: option.ink, opacity: .15 }} /><span className="mt-auto h-1.5 w-4 rounded" style={{ background: option.accent }} /></span></span>
        <span className="block text-[11px] font-medium text-ink">{option.name}</span><span className="block text-[9px] leading-4 text-ink-3">{option.detail}</span>
      </button>)}</div>
      <CustomThemes selected={theme} />
    </div>, document.body)}
  </>;
}
