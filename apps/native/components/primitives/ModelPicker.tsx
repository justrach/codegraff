"use client";
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { createPortal } from "react-dom";
import type { ModelChoice } from "@/lib/acp-client";

type Props = {
  models: ModelChoice[]; selected: ModelChoice; anchor: RefObject<HTMLButtonElement | null>;
  onSelect(model: ModelChoice): void; onClose(): void;
};
export default function ModelPicker({ models, selected, anchor, onSelect, onClose }: Props) {
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const [position, setPosition] = useState<{ left: number; top: number; width: number; height: number } | null>(null);
  const panel = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const search = useRef<HTMLInputElement>(null);
  const keyboard = useRef(false);
  const focused = useRef(false);
  const id = useId();
  const callbacks = useRef({ onSelect, onClose }); callbacks.current = { onSelect, onClose };
  const shown = useMemo(() => {
    const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
    if (terms.length) return models.filter(model => terms.every(term => `${model.name} ${model.tag ?? ""} ${model.provider ?? ""}`.toLowerCase().includes(term)));
    // The current choice is immediately visible; other models retain graff's order.
    return [selected, ...models.filter(model => model.key !== selected.key)];
  }, [models, query, selected]);
  useLayoutEffect(() => {
    const place = () => {
      const rect = anchor.current?.getBoundingClientRect(); if (!rect) return;
      const margin = 12, safeTop = document.documentElement.dataset.desktop === "true" ? 48 : margin;
      const width = Math.min(360, window.innerWidth - margin * 2);
      const above = Math.max(0, rect.top - safeTop - 8), below = Math.max(0, window.innerHeight - rect.bottom - margin - 8);
      const up = above >= Math.min(420, below);
      const maxHeight = Math.min(420, up ? above : below);
      const height = Math.min(maxHeight, 125 + Math.max(1, models.length) * 44);
      setPosition({ left: Math.max(margin, Math.min(rect.left, window.innerWidth - width - margin)),
        top: up ? Math.max(safeTop, rect.top - height - 8) : rect.bottom + 8, width, height });
    };
    place();
    const scroll = (event: Event) => { if (!panel.current?.contains(event.target as Node)) place(); };
    window.addEventListener("resize", place); document.addEventListener("scroll", scroll, true);
    return () => { window.removeEventListener("resize", place); document.removeEventListener("scroll", scroll, true); };
  }, [anchor, models.length]);
  useLayoutEffect(() => { if (position && !focused.current) { search.current?.focus({ preventScroll: true }); focused.current = true; } }, [position]);
  useEffect(() => {
    const outside = (event: PointerEvent) => {
      if (!panel.current?.contains(event.target as Node) && !anchor.current?.contains(event.target as Node)) callbacks.current.onClose();
    };
    document.addEventListener("pointerdown", outside);
    return () => document.removeEventListener("pointerdown", outside);
  }, [anchor]);
  useLayoutEffect(() => {
    if (!keyboard.current) return;
    keyboard.current = false;
    const viewport = list.current, row = viewport?.children[active] as HTMLElement | undefined;
    if (!viewport || !row) return;
    if (row.offsetTop < viewport.scrollTop) viewport.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > viewport.scrollTop + viewport.clientHeight) viewport.scrollTop = row.offsetTop + row.offsetHeight - viewport.clientHeight;
  }, [active]);
  const close = () => { callbacks.current.onClose(); anchor.current?.focus({ preventScroll: true }); };
  return createPortal(<div ref={panel} role="dialog" aria-label="Choose a model" className="fixed z-[200] flex flex-col overflow-hidden rounded-xl border border-line bg-surface shadow-overlay"
    style={{ ...position, visibility: position ? "visible" : "hidden" }} onKeyDown={event => {
      event.stopPropagation();
      if (event.key === "Escape") { event.preventDefault(); close(); }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); keyboard.current = true; setActive(index => Math.max(0, Math.min(shown.length - 1, index + (event.key === "ArrowDown" ? 1 : -1)))); }
      if (event.key === "Enter" && event.target === search.current && shown[active]) { event.preventDefault(); callbacks.current.onSelect(shown[active]); }
      if (event.key === "Tab") {
        const buttons = [search.current, ...Array.from(panel.current?.querySelectorAll<HTMLButtonElement>('button:not([role="option"])') ?? [])].filter(Boolean) as HTMLElement[];
        const index = buttons.indexOf(document.activeElement as HTMLElement);
        event.preventDefault(); buttons[(index + (event.shiftKey ? buttons.length - 1 : 1)) % buttons.length]?.focus();
      }
    }}>
    <div className="flex shrink-0 items-center justify-between px-3 pt-2.5 pb-2"><strong className="text-xs font-medium">Model</strong><button aria-label="Close model picker" onClick={close} className="flex size-6 items-center justify-center rounded text-ink-3 hover:bg-hover">×</button></div>
    <div className="shrink-0 border-b border-line px-3 pb-2.5"><input ref={search} role="combobox" aria-label="Filter models" aria-expanded="true" aria-controls={`${id}-list`} aria-activedescendant={shown[active] ? `${id}-${active}` : undefined} aria-autocomplete="list"
      placeholder="Search models or providers…" value={query} onChange={event => { setQuery(event.target.value); setActive(0); if (list.current) list.current.scrollTop = 0; }}
      className="h-8 w-full rounded-md border border-line bg-field px-2.5 text-xs text-ink outline-accent placeholder:text-ink-3" /></div>
    <div ref={list} id={`${id}-list`} role="listbox" aria-label="Available models" className="relative min-h-0 flex-1 overflow-y-auto overscroll-contain p-1.5">
      {shown.map((model, index) => <button id={`${id}-${index}`} key={model.key} role="option" aria-selected={model.key === selected.key} tabIndex={-1}
        title={`${model.name}${model.tag ? ` · ${model.tag}` : ""}`} onPointerMove={() => setActive(index)} onMouseDown={event => event.preventDefault()} onClick={() => callbacks.current.onSelect(model)}
        className={`flex min-h-11 w-full items-center gap-2 rounded-md px-2.5 py-1.5 text-left ${index === active ? "bg-hover" : "hover:bg-hover"}`}>
        <span className="min-w-0 flex-1"><span className="block truncate text-[13px] font-medium text-ink">{model.name}</span><span className="block truncate text-[10px] text-ink-3">{model.tag ?? model.provider ?? "Available"}</span></span>
        {model.key === selected.key && <span className="shrink-0 text-[10px] text-accent-ink">Current ✓</span>}
      </button>)}
      {!shown.length && <p role="status" className="px-3 py-6 text-center text-xs text-ink-3">No matching models. Try another name or provider.</p>}
    </div>
    <div className="flex shrink-0 justify-between border-t border-line px-3 py-2 text-[10px] text-ink-3"><span>{shown.length} {shown.length === 1 ? "model" : "models"}</span><span>↑↓ to browse · Enter to select</span></div>
  </div>, document.body);
}
