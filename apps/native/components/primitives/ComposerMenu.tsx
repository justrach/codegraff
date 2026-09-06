"use client";
import { useLayoutEffect, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import { Icon, GLYPHS, BRANDS, SOURCES } from "./prompt-demo";
type Row = { key: string; name: string; desc: string };
type Props = {
  anchor: RefObject<HTMLDivElement | null>; menu: "at" | "slash" | "skill"; rows: Row[]; query: string;
  active: number; engaged: boolean; setActive: (index: number) => void; setEngaged: (value: boolean) => void;
  connected: boolean; setConnected: (value: boolean) => void; demo: boolean; onPick: (row: Row) => void;
};
export default function ComposerMenu({ anchor, menu, rows, query, active, engaged, setActive, setEngaged, connected, setConnected, demo, onPick }: Props) {
  const panel = useRef<HTMLDivElement>(null), list = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ top: number; left: number; width: number; maxHeight: number }>();
  useLayoutEffect(() => {
    const place = () => {
      const rect = anchor.current?.getBoundingClientRect(); if (!rect) return;
      const title = document.querySelector('[data-desktop-titlebar]')?.getBoundingClientRect().bottom ?? 0;
      const safeTop = Math.max(12, title + 8), above = Math.max(0, rect.top - safeTop - 8);
      const below = Math.max(0, innerHeight - rect.bottom - 20), up = above >= Math.min(360, below);
      const height = Math.min(360, up ? above : below, Math.max(1, rows.length) * 36 + 40);
      const width = Math.min(rect.width, innerWidth - 24);
      setPosition({ top: up ? rect.top - height - 8 : rect.bottom + 8,
        left: Math.max(12, Math.min(rect.left, innerWidth - width - 12)), width, maxHeight: height });
    };
    place();
    const scroll = (event: Event) => { if (!panel.current?.contains(event.target as Node)) place(); };
    window.addEventListener('resize', place); document.addEventListener('scroll', scroll, true);
    const observer = new ResizeObserver(place); if (anchor.current) observer.observe(anchor.current);
    return () => { window.removeEventListener('resize', place); document.removeEventListener('scroll', scroll, true); observer.disconnect(); };
  }, [anchor, rows.length]);
  useLayoutEffect(() => {
    const viewport = list.current, row = viewport?.children[active] as HTMLElement | undefined;
    if (!viewport || !row) return;
    if (row.offsetTop < viewport.scrollTop) viewport.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > viewport.scrollTop + viewport.clientHeight) viewport.scrollTop = row.offsetTop + row.offsetHeight - viewport.clientHeight;
  }, [active, query, position]);
  return createPortal(<div ref={panel} data-composer-menu className="fixed z-[200] flex flex-col overflow-hidden rounded-xl border border-line bg-surface p-1 shadow-raised"
    style={{ ...position, visibility: position ? "visible" : "hidden" }} onMouseLeave={() => setEngaged(false)}>
    <div ref={list} role="listbox" aria-label={menu === "slash" ? "Commands" : menu === "skill" ? "GUI skills" : "Sources and files"} className="relative min-h-0 overflow-y-auto overscroll-contain">
      {rows.map((row, i) => {
        const source = menu === "at" ? SOURCES.find(s => s.key === row.key) : undefined;
        const mark = source ? source.brand ? BRANDS[source.brand] : <Icon size={15}>{GLYPHS[source.glyph ?? "clip"]}</Icon>
          : row.key.startsWith("file:") ? <Icon size={15}>{GLYPHS.file}</Icon> : null;
        return <button key={row.key} type="button" role="option" aria-selected={i === active} title={`${row.name} — ${row.desc}`}
          onMouseDown={event => event.preventDefault()} onMouseEnter={() => { setActive(i); setEngaged(true); }} onClick={() => onPick(row)}
          className={`flex h-9 w-full items-center gap-2.5 rounded-md px-2 text-left ${engaged && i === active ? "bg-hover" : "hover:bg-hover"}`}>
          {mark && <span className="flex size-5 shrink-0 items-center justify-center text-ink-2">{mark}</span>}
          <span className="max-w-[55%] shrink-0 truncate text-[12.5px] font-medium text-ink">{row.name}</span>
          <span className="min-w-0 flex-1 truncate text-xs text-ink-3">{row.desc}</span>
          {source?.connect && <span onClick={event => { event.stopPropagation(); setConnected(!connected); }} className="shrink-0 text-xs text-accent-ink">{connected ? "Connected" : "Connect"}</span>}
        </button>;
      })}
      {!rows.length && <div role="status" className="px-2 py-3 text-xs text-ink-3">No matches for “{query}”</div>}
    </div>
    <div className="mt-1 shrink-0 border-t border-line px-2 py-1.5 text-[11px] text-ink-3">
      {menu === "slash" ? "Search commands · ↑↓ then Enter to select" : menu === "skill" ? "GUI skills · ↑↓ then Enter to select" : demo ? "Search sources & files" : "Search files or GUI skills · use $ for skills only"}
    </div>
  </div>, document.body);
}
