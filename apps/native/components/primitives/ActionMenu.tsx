"use client";
import { useId, useRef, useState, type ReactNode } from "react";

/** Native popover: top-layer placement, outside dismissal, Escape and focus return. */
export default function ActionMenu({ label, text = "…", children, className = "", wide = false }: {
  label: string; text?: ReactNode; wide?: boolean; children: ReactNode; className?: string;
}) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const position = () => {
    if (!panel.current || !trigger.current) return;
    const anchor = trigger.current.getBoundingClientRect();
    const box = panel.current.getBoundingClientRect();
    panel.current.style.left = `${Math.max(8, Math.min(anchor.right - box.width, window.innerWidth - box.width - 8))}px`;
    panel.current.style.top = `${Math.max(8, Math.min(anchor.bottom + 6, window.innerHeight - box.height - 8))}px`;
  };
  return <span className={className}>
    <button ref={trigger} type="button" popoverTarget={id} aria-label={label} aria-expanded={open} aria-haspopup="dialog"
      className="flex h-7 min-w-7 items-center justify-center rounded-md px-2 text-xs text-ink-2 hover:bg-hover focus-visible:outline-auto">{text}</button>
    <div ref={panel} id={id} popover="auto" role={open ? "dialog" : undefined} aria-label={label}
      onToggle={event => { const opened = event.newState === "open"; setOpen(opened); if (opened) { position(); panel.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus(); } }}
      onClick={event => { if ((event.target as Element).closest("button:not(:disabled)")) panel.current?.hidePopover(); }}
      className={`fixed m-0 max-h-[calc(100dvh-16px)] ${wide ? "w-80 max-w-[calc(100vw-16px)]" : "w-52"} overflow-y-auto rounded-lg border border-line bg-surface p-1.5 text-ink shadow-overlay [&>button]:flex [&>button]:w-full [&>button]:justify-start [&>button]:rounded-md [&>button]:px-3 [&>button]:py-2 [&>button]:text-left [&>button]:text-xs [&>button:hover]:bg-hover`}>
      {children}
    </div>
  </span>;
}

/** Dialogs launched from a menu return focus to its visible trigger. */
export function restoreActionFocus(trigger: HTMLButtonElement | null) {
  const menu = trigger?.closest<HTMLElement>("[popover]");
  if (menu && !menu.matches(":popover-open")) {
    document.querySelector<HTMLButtonElement>(`[popovertarget="${CSS.escape(menu.id)}"]`)?.focus();
  } else trigger?.focus();
}
