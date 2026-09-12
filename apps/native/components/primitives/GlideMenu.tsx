"use client";

import { useRef, useState, type ReactNode } from "react";

type GlideMenuProps = {
  children: ReactNode;
  className?: string;
  highlightClassName?: string;
  rowSelector?: string;
};

/** A single hover layer that glides between interactive menu rows. */
export default function GlideMenu({
  children,
  className = "",
  highlightClassName = "inset-x-0 rounded-[8px] bg-hover",
  rowSelector = "[data-menu-row]",
}: GlideMenuProps) {
  const ref = useRef<HTMLDivElement>(null);
  const highlightedRow = useRef<HTMLElement | null>(null);
  const [box, setBox] = useState<{ top: number; height: number } | null>(null);
  const [visible, setVisible] = useState(false);
  const [gliding, setGliding] = useState(false);

  const moveTo = (target: EventTarget | null, relatedTarget: EventTarget | null) => {
    const container = ref.current;
    if (!(target instanceof Element) || !container) return;
    const row = target.closest(rowSelector);
    if (!(row instanceof HTMLElement) || !container.contains(row)) return;
    // Moving across a row's icon and label should not measure or rerender it.
    if (visible && highlightedRow.current === row && relatedTarget instanceof Element
      && relatedTarget.closest(rowSelector) === row) return;
    highlightedRow.current = row;
    const containerRect = container.getBoundingClientRect();
    const rowRect = row.getBoundingClientRect();
    setGliding(visible && box !== null);
    const top = rowRect.top - containerRect.top + container.scrollTop - container.clientTop;
    setBox(previous => previous?.top === top && previous.height === rowRect.height
      ? previous : { top, height: rowRect.height });
    setVisible(true);
  };

  return (
    <div
      ref={ref}
      onMouseOver={(event) => moveTo(event.target, event.relatedTarget)}
      onMouseLeave={() => setVisible(false)}
      onFocusCapture={(event) => moveTo(event.target, event.relatedTarget)}
      onBlurCapture={(event) => {
        if (!ref.current?.contains(event.relatedTarget as Node | null)) setVisible(false);
      }}
      className={`group/glide-menu relative ${className}`}
    >
      <span
        aria-hidden
        className={`motion-glide pointer-events-none absolute ${highlightClassName}`}
        style={{
          top: 0,
          transform: `translateY(${box?.top ?? 0}px)`,
          height: box?.height ?? 0,
          opacity: box && visible ? 1 : 0,
          // First entry appears at its row; subsequent moves glide between rows.
          transitionProperty: visible && gliding ? undefined : "opacity",
        }}
      />
      {children}
    </div>
  );
}
