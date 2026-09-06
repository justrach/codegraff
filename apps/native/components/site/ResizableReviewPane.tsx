"use client";
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import styles from "./ChangesPane.module.css";

const storageKey = "graff.changes.width";
const defaultWidth = 650;
export default function ResizableReviewPane({ children }: { children: ReactNode }) {
  const frame = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; width: number } | null>(null);
  const [preferred, setPreferred] = useState(defaultWidth);
  const [maximum, setMaximum] = useState(defaultWidth);
  const [dragging, setDragging] = useState(false);
  const minimum = Math.min(300, maximum);
  const width = Math.max(minimum, Math.min(maximum, preferred));
  const save = (value: number) => {
    setPreferred(value);
    try { localStorage.setItem(storageKey, String(value)); } catch { /* Optional preference. */ }
  };
  useLayoutEffect(() => {
    try { const saved = Number(localStorage.getItem(storageKey)); if (Number.isFinite(saved) && saved >= 200) setPreferred(saved); } catch { /* Use default. */ }
    const parent = frame.current?.parentElement;
    if (!parent) return;
    const measure = () => {
      const available = parent.clientWidth;
      setMaximum(Math.max(0, available - Math.min(320, available / 2) - 10));
    };
    measure();
    const observer = new ResizeObserver(measure); observer.observe(parent);
    return () => observer.disconnect();
  }, []);
  useLayoutEffect(() => {
    if (!dragging) return;
    const { cursor, userSelect } = document.body.style;
    document.body.style.cursor = "col-resize"; document.body.style.userSelect = "none";
    return () => { document.body.style.cursor = cursor; document.body.style.userSelect = userSelect; };
  }, [dragging]);
  return <div ref={frame} className="relative flex min-h-0 min-w-0 shrink-0" style={{ width }}>
    <div role="separator" aria-label="Resize changes panel" aria-orientation="vertical" tabIndex={0}
      aria-valuemin={Math.round(minimum)} aria-valuemax={Math.round(maximum)} aria-valuenow={Math.round(width)}
      title="Drag to resize · Double-click to reset" className={styles.resize} data-dragging={dragging || undefined}
      onPointerDown={event => {
        if (event.button !== 0) return;
        event.preventDefault(); event.currentTarget.focus({ preventScroll: true });
        drag.current = { x: event.clientX, width };
        event.currentTarget.setPointerCapture(event.pointerId); setDragging(true);
      }}
      onPointerMove={event => {
        if (drag.current) setPreferred(Math.max(minimum, Math.min(maximum, drag.current.width + drag.current.x - event.clientX)));
      }}
      onPointerUp={event => {
        if (!drag.current) return;
        const next = Math.max(minimum, Math.min(maximum, drag.current.width + drag.current.x - event.clientX));
        drag.current = null; setDragging(false); save(next);
        event.currentTarget.releasePointerCapture(event.pointerId);
      }}
      onLostPointerCapture={() => { drag.current = null; setDragging(false); }}
      onPointerCancel={() => { drag.current = null; setDragging(false); }}
      onDoubleClick={() => save(defaultWidth)}
      onKeyDown={event => {
        const next = event.key === "ArrowLeft" ? width + 20 : event.key === "ArrowRight" ? width - 20 : event.key === "Home" ? minimum : event.key === "End" ? maximum : null;
        if (next !== null) { event.preventDefault(); save(Math.max(minimum, Math.min(maximum, next))); }
      }} />
    {children}
  </div>;
}
