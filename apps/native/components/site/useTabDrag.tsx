"use client";
import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type MouseEvent } from "react";
import type { TabDrop } from "@/lib/tab-drop";
import { captureTabLayout, settleTabLayout } from "./tab-drag-motion";
import styles from "./tab-drag.module.css";
type Preview = { drop: TabDrop; left: number; top: number; width: number; height: number; label: string };
/** Pointer dragging stays inside the renderer: no native drag session, new
 * window or worker. Only IDs move; mounted conversations keep their state. */
export function useTabDrag(onDrop: (id: number, drop: TabDrop) => void) {
  const [preview, setPreview] = useState<Preview | null>(null);
  const [title, setTitle] = useState<string | null>(null);
  const ghost = useRef<HTMLDivElement>(null), position = useRef({ x: 0, y: 0 });
  const pendingLayout = useRef<ReturnType<typeof captureTabLayout> | null>(null);
  const animations = useRef<Animation[]>([]);
  const cleanup = useRef<(() => void) | null>(null);
  const suppress = useRef(false);
  const latest = useRef(onDrop); latest.current = onDrop;
  const paintGhost = () => {
    const left = Math.max(8, Math.min(position.current.x+14, innerWidth-244));
    const top = Math.max(8, Math.min(position.current.y+18, innerHeight-58));
    if (ghost.current) ghost.current.style.transform = `translate3d(${left}px, ${top}px, 0)`;
  };
  useLayoutEffect(() => {
    paintGhost();
    if (pendingLayout.current) {
      animations.current = settleTabLayout(pendingLayout.current);
      for (const animation of animations.current) {
        const release = () => { animations.current = animations.current.filter(item => item !== animation); };
        animation.onfinish = release; animation.oncancel = release;
      }
      pendingLayout.current = null;
    }
  });
  useEffect(() => () => { cleanup.current?.(); animations.current.forEach(animation => animation.cancel()); }, []);
  function begin(event: ReactPointerEvent, id: number) {
    if (event.button !== 0 || (event.target as Element).closest('[aria-label="Close tab"]')) return;
    cleanup.current?.();
    animations.current.forEach(animation => animation.cancel());
    const source = event.currentTarget as HTMLElement;
    const sourceTitle = source.querySelector('button[aria-pressed]')?.textContent || 'Chat';
    const x = event.clientX, y = event.clientY, pointerId = event.pointerId;
    let dragging = false, candidate: Preview | null = null, frame = 0;
    const hit = (x: number, y: number): Preview | null => {
      const element = document.elementFromPoint(x, y);
      const tab = element?.closest<HTMLElement>('[data-tab-id]');
      if (tab && Number(tab.dataset.tabId) !== id) {
        const r = tab.getBoundingClientRect(), after = x > r.left + r.width / 2;
        return { drop: { kind: "tab", id: Number(tab.dataset.tabId), after }, left: after ? r.right - 2 : r.left, top: r.top, width: 3, height: r.height, label: "Move tab" };
      }
      const pane = element?.closest<HTMLElement>('[data-chat]');
      if (!pane || Number(pane.dataset.chat) === id) return null;
      const r = pane.getBoundingClientRect();
      const sides = [
        { edge: "left" as const, distance: (x - r.left) / r.width, horizontal: true },
        { edge: "right" as const, distance: (r.right - x) / r.width, horizontal: true },
        { edge: "top" as const, distance: (y - r.top) / r.height, horizontal: false },
        { edge: "bottom" as const, distance: (r.bottom - y) / r.height, horizontal: false },
      ];
      const side = sides.sort((a, b) => a.distance - b.distance)[0];
      if (!side || side.distance > 0.3) return null;
      return { drop: { kind: "split", id: Number(pane.dataset.chat), edge: side.edge },
        left: r.left + (side.edge === "right" ? r.width / 2 : 0), top: r.top + (side.edge === "bottom" ? r.height / 2 : 0),
        width: side.horizontal ? r.width / 2 : r.width, height: side.horizontal ? r.height : r.height / 2,
        label: `Split ${ { left: "left", right: "right", top: "above", bottom: "below" }[side.edge]}` };
    };
    const move = (e: PointerEvent) => {
      if (e.pointerId !== pointerId) return;
      if (!dragging && Math.hypot(e.clientX - x, e.clientY - y) < 6) return;
      if (!dragging) { setTitle(sourceTitle); source.style.opacity = '0.45'; }
      dragging = true; e.preventDefault();
      position.current = { x: e.clientX, y: e.clientY };
      if (!frame) frame = requestAnimationFrame(() => {
        frame = 0; paintGhost();
        const next = hit(position.current.x, position.current.y);
        // Coalesce hit testing as well as painting; unchanged targets need no React update.
        if (JSON.stringify(next) !== JSON.stringify(candidate)) { candidate = next; setPreview(next); }
      });
    };
    const clear = () => {
      window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", cancel); window.removeEventListener("keydown", key); window.removeEventListener("blur", cancel);
      cancelAnimationFrame(frame); source.style.opacity = ''; setTitle(null);
      setPreview(null); cleanup.current = null;
      if (dragging) { suppress.current = true; setTimeout(() => { suppress.current = false; }, 0); }
    };
    const up = (e: PointerEvent) => {
      if (e.pointerId !== pointerId) return;
      const drop = dragging ? hit(e.clientX, e.clientY)?.drop : undefined;
      if (drop) pendingLayout.current = captureTabLayout();
      clear(); if (drop) latest.current(id, drop);
    };
    const cancel = () => clear();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); clear(); } };
    window.addEventListener("pointermove", move, { passive: false }); window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", cancel); window.addEventListener("keydown", key); window.addEventListener("blur", cancel);
    cleanup.current = clear;
  }
  return {
    begin,
    suppressClick(event: MouseEvent) { if (suppress.current) { event.preventDefault(); event.stopPropagation(); } },
    overlay: <>
      {preview && <div aria-hidden="true" data-tab-drop={preview.drop.kind} className={styles.target} style={{ left: preview.left, top: preview.top, width: preview.width, height: preview.height }}>
        {preview.drop.kind === "split" && <span className={styles.label}>
          <span className={styles.icon} data-vertical={preview.drop.edge === 'top' || preview.drop.edge === 'bottom'}><span /><span /></span>
          {preview.label}
        </span>}
      </div>}
      {title && <div aria-hidden="true" data-tab-drag-ghost ref={ghost} className={styles.ghost}>
        <div className={styles.card}><span className={styles.grip}>⠿</span><span className={styles.title}>{title}</span></div>
      </div>}
    </>,
  };
}
