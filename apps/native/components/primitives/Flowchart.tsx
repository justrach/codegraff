"use client";

import { useEffect, useRef, useState } from "react";
import { useLayoutEffect } from "react";

/* ─────────────────────────────────────────────────────────
 * FLOWCHART — an agent workflow on a dotted editor canvas.
 * Two steps: a Trigger card and an If/Else condition card,
 * joined by a measured connector. Cards drag anywhere on
 * the canvas; the connector follows. Condition chips open
 * real dropdowns (same menu as the PromptBar model picker).
 * ───────────────────────────────────────────────────────── */

const PURPLE = "#9a5cff";
const AMBER = "#f09a2f";

const mix = (hue: string, pct: number, base = "var(--surface)") =>
  `color-mix(in srgb, ${hue} ${pct}%, ${base})`;

/* ── layout constants ── */
const PAD_Y = 24;
const ROW_GAP = 64;
const PILL_OFFSET = 30; // kind pill + gap above a card

type StepNode = {
  id: string;
  row: number;
  x: number; // 0–1 center of the node
  w: number;
  kind?: { label: string; hue: string };
  hue?: string;
  title?: string;
  caption?: string;
  condition?: boolean; // renders the if/else chip rows instead
};

const NODES: StepNode[] = [
  {
    id: "trigger",
    row: 0,
    x: 0.5,
    w: 300,
    kind: { label: "Trigger", hue: PURPLE },
    hue: PURPLE,
    title: "New order created",
    caption: "Trigger when a new order is created",
  },
  {
    id: "cond",
    row: 1,
    x: 0.5,
    w: 356,
    kind: { label: "If / Else", hue: AMBER },
    condition: true,
  },
];

const EDGES = [{ from: "trigger", to: "cond" }];

/* estimated heights for the first paint; measured immediately after */
const EST_H: Record<string, number> = { trigger: 92, cond: 134 };

const PROPERTIES = ["flavor", "topping", "size", "scoops"];
const FLAVORS = [
  { name: "Rocky Road", tag: "Classic" },
  { name: "Mint Chip", tag: "Classic" },
  { name: "Pistachio", tag: "Seasonal" },
  { name: "Bubblegum", tag: "Retro" },
];
const TOPPINGS = [
  { name: "Brown butter bourbon brittle crunch" },
  { name: "Rainbow sprinkles" },
  { name: "Hot fudge" },
  { name: "Candied pecans" },
];

/* ── icons ── */
function ConeIcon({ size = 16 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d="m7 11 4.08 10.35a1 1 0 0 0 1.84 0L17 11" />
      <path d="M17 7A5 5 0 0 0 7 7" />
      <path d="M17 7a2 2 0 0 1 0 4H7a2 2 0 0 1 0-4" />
    </svg>
  );
}

function Chevron() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" className="shrink-0 text-ink-3">
      <path d="m6 9 6 6 6-6" />
    </svg>
  );
}

function Handle() {
  return (
    <svg width="10" height="16" viewBox="0 0 10 16" className="shrink-0 cursor-grab text-ink-3/70">
      {[3, 8, 13].flatMap((y) => [
        <circle key={`l${y}`} cx="3" cy={y} r="1.1" fill="currentColor" />,
        <circle key={`r${y}`} cx="7.5" cy={y} r="1.1" fill="currentColor" />,
      ])}
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 6L9 17l-5-5" />
    </svg>
  );
}

/* ── dropdown menu — same pattern as the PromptBar model picker ── */
function Menu({
  items,
  value,
  width,
  align,
  onPick,
}: {
  items: { name: string; tag?: string }[];
  value: string;
  width: string;
  align: "left" | "right";
  onPick: (name: string) => void;
}) {
  const [hovered, setHovered] = useState<number | null>(null);
  const rowRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const [box, setBox] = useState<{ top: number; height: number } | null>(null);

  const valueIndex = items.findIndex((item) => item.name === value);
  useLayoutEffect(() => {
    const row = rowRefs.current[hovered ?? valueIndex];
    if (row) setBox({ top: row.offsetTop, height: row.offsetHeight });
  }, [hovered, valueIndex]);

  return (
    <div
      onMouseLeave={() => setHovered(null)}
      className={`absolute bottom-full z-20 mb-1.5 rounded-[10px] bg-surface p-1 shadow-raised ${width}
        ${align === "right" ? "right-0" : "left-0"}`}
      style={{
        animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both",
        transformOrigin: align === "right" ? "bottom right" : "bottom left",
      }}
    >
      <span
        aria-hidden
        className="pointer-events-none absolute inset-x-1 rounded-[6px] bg-hover"
        style={{
          top: box?.top ?? 0,
          height: box?.height ?? 0,
          opacity: box && hovered !== null ? 1 : 0,
          transition:
            "top 220ms cubic-bezier(0.23,1,0.32,1), height 220ms cubic-bezier(0.23,1,0.32,1), opacity 150ms ease",
        }}
      />
      {items.map((item, i) => (
        <button
          key={item.name}
          type="button"
          ref={(el) => {
            rowRefs.current[i] = el;
          }}
          onMouseEnter={() => setHovered(i)}
          onClick={() => onPick(item.name)}
          className="relative z-10 flex h-7.5 w-full cursor-pointer items-center gap-2 rounded-[6px] px-2 text-left"
        >
          <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-ink">{item.name}</span>
          {item.tag && <span className="shrink-0 text-[11px] text-ink-3">{item.tag}</span>}
          <span className={`shrink-0 text-ink ${item.name === value ? "" : "invisible"}`}>
            <CheckIcon />
          </span>
        </button>
      ))}
    </div>
  );
}

/* ── chips used inside the condition card ── */
function SourceChip() {
  return (
    <span
      data-ui
      className="inline-flex h-6 shrink-0 items-center gap-1 rounded-[6px] bg-surface px-1.5 text-[12px] font-medium text-ink shadow-btn"
    >
      <span className="text-ink-2">
        <ConeIcon size={12} />
      </span>
      order
    </span>
  );
}

function SelectChip({
  id,
  value,
  dot,
  items,
  width,
  align = "left",
  open,
  onToggle,
  onPick,
}: {
  id: string;
  value: string;
  dot?: boolean;
  items: { name: string; tag?: string }[];
  width: string;
  align?: "left" | "right";
  open: boolean;
  onToggle: (id: string) => void;
  onPick: (id: string, name: string) => void;
}) {
  return (
    <span data-ui className="relative inline-flex min-w-0">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => onToggle(id)}
        className={`inline-flex h-6 min-w-0 cursor-pointer items-center gap-1 rounded-[6px] px-1.5
          text-[12px] font-medium text-ink transition-colors duration-100
          ${open ? "bg-hover-2" : "bg-field hover:bg-hover-2"}`}
      >
        {dot && <span className="size-1.5 shrink-0 rounded-full" style={{ background: AMBER }} />}
        <span className="min-w-0 truncate">{value}</span>
        <Chevron />
      </button>
      {open && (
        <Menu
          items={items}
          value={value}
          width={width}
          align={align}
          onPick={(name) => onPick(id, name)}
        />
      )}
    </span>
  );
}

function ConditionBody() {
  const [values, setValues] = useState<Record<string, string>>({
    prop1: "flavor",
    val1: "Rocky Road",
    prop2: "topping",
    val2: "Brown butter bourbon brittle crunch",
  });
  const [open, setOpen] = useState<string | null>(null);

  /* click anywhere else closes the menu */
  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => {
      if (!(event.target as Element).closest("[data-ui]")) setOpen(null);
    };
    document.addEventListener("pointerdown", close);
    return () => document.removeEventListener("pointerdown", close);
  }, [open]);

  const toggle = (id: string) => setOpen((current) => (current === id ? null : id));
  const pick = (id: string, name: string) => {
    setValues((current) => ({ ...current, [id]: name }));
    setOpen(null);
  };

  const chip = (id: string, items: { name: string; tag?: string }[], width: string, extra?: object) => (
    <SelectChip
      id={id}
      value={values[id]}
      items={items}
      width={width}
      open={open === id}
      onToggle={toggle}
      onPick={pick}
      {...extra}
    />
  );

  return (
    <div className="flex flex-col gap-1.5 px-3 py-2.5">
      <div className="flex min-w-0 items-center gap-1.5">
        <Handle />
        <span className="w-7 text-[12.5px] text-ink-2">If</span>
        <SourceChip />
        {chip("prop1", PROPERTIES.map((name) => ({ name })), "w-36")}
        <span className="text-[12.5px] text-ink-2">is</span>
        {chip("val1", FLAVORS, "w-44", { dot: true, align: "right" })}
      </div>
      <div className="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-1.5">
        <Handle />
        <span className="w-7 text-[12.5px] text-ink-2">and</span>
        <SourceChip />
        {chip("prop2", PROPERTIES.map((name) => ({ name })), "w-36")}
        <span className="text-[12.5px] text-ink-2">is</span>
        <span className="max-w-full pl-[49px]">
          {chip("val2", TOPPINGS, "w-64", { dot: true })}
        </span>
      </div>
    </div>
  );
}

function StepBody({ node }: { node: StepNode }) {
  return (
    <div className="flex items-center gap-2.5 px-3 py-2.5">
      <span
        className="flex size-9 shrink-0 items-center justify-center rounded-[8px]"
        style={{
          background: mix(node.hue!, 12),
          color: node.hue,
          boxShadow: `0 0 0 1px ${mix(node.hue!, 20)}`,
        }}
      >
        <ConeIcon />
      </span>
      <span className="min-w-0 text-left">
        <span className="block truncate text-[13px] font-semibold text-ink">{node.title}</span>
        <span className="mt-0.5 block text-[12px] leading-snug text-ink-2">{node.caption}</span>
      </span>
    </div>
  );
}

/* ── the canvas ── */
export default function Flowchart() {
  const canvasRef = useRef<HTMLDivElement>(null);
  const nodeRefs = useRef(new Map<string, HTMLElement>());
  const [width, setWidth] = useState(0);
  const [heights, setHeights] = useState<Record<string, number>>(EST_H);
  const [selected, setSelected] = useState<string | null>(null);
  const [offsets, setOffsets] = useState<Record<string, { dx: number; dy: number }>>({});
  const drag = useRef<{
    id: string;
    startX: number;
    startY: number;
    baseDx: number;
    baseDy: number;
    moved: boolean;
  } | null>(null);

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const measure = () => {
      setWidth(canvas.clientWidth);
      setHeights((prev) => {
        const next = { ...prev };
        let changed = false;
        nodeRefs.current.forEach((el, id) => {
          const h = el.offsetHeight;
          if (h && Math.abs(h - (next[id] ?? 0)) > 0.5) {
            next[id] = h;
            changed = true;
          }
        });
        return changed ? next : prev;
      });
    };

    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(canvas);
    nodeRefs.current.forEach((el) => observer.observe(el));
    return () => observer.disconnect();
  }, []);

  /* rows → y offsets from measured node heights */
  const rows = [...new Set(NODES.map((n) => n.row))].sort((a, b) => a - b);
  const rowH = rows.map((r) =>
    Math.max(...NODES.filter((n) => n.row === r).map((n) => heights[n.id] ?? 90)),
  );
  const rowY: number[] = [];
  rows.forEach((_, i) => {
    rowY[i] = i === 0 ? PAD_Y : rowY[i - 1] + rowH[i - 1] + ROW_GAP;
  });
  const canvasH = rowY[rows.length - 1] + rowH[rows.length - 1] + PAD_Y;

  const cw = width || 480;
  const place = (n: StepNode) => {
    const w = Math.min(n.w, cw * 0.92);
    const off = offsets[n.id];
    return {
      w,
      cx: n.x * cw + (off?.dx ?? 0),
      top: rowY[rows.indexOf(n.row)] + (off?.dy ?? 0),
    };
  };

  /* card anchor points (pills sit above the card, so offset the top) */
  const anchors = (n: StepNode) => {
    const { cx, top } = place(n);
    return {
      top: { x: cx, y: top + (n.kind ? PILL_OFFSET : 0) },
      bottom: { x: cx, y: top + (heights[n.id] ?? 90) },
    };
  };

  const bezier = (edge: { from: string; to: string }) => {
    const from = anchors(NODES.find((n) => n.id === edge.from)!).bottom;
    const to = anchors(NODES.find((n) => n.id === edge.to)!).top;
    const k = Math.min(Math.max(Math.abs(to.y - from.y) * 0.55, 24), 84);
    return `M ${from.x} ${from.y} C ${from.x} ${from.y + k}, ${to.x} ${to.y - k}, ${to.x} ${to.y}`;
  };

  /* ── dragging ── */
  const onPointerDown = (node: StepNode) => (event: React.PointerEvent<HTMLDivElement>) => {
    if ((event.target as Element).closest("[data-ui]")) return;
    const off = offsets[node.id];
    drag.current = {
      id: node.id,
      startX: event.clientX,
      startY: event.clientY,
      baseDx: off?.dx ?? 0,
      baseDy: off?.dy ?? 0,
      moved: false,
    };
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  };

  const onPointerMove = (node: StepNode) => (event: React.PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.id !== node.id) return;
    const dx = d.baseDx + event.clientX - d.startX;
    const dy = d.baseDy + event.clientY - d.startY;
    if (!d.moved && Math.hypot(dx - d.baseDx, dy - d.baseDy) < 3) return;
    d.moved = true;

    /* keep the card inside the canvas */
    const { w } = place(node);
    const h = heights[node.id] ?? 90;
    const baseCx = node.x * cw;
    const baseTop = rowY[rows.indexOf(node.row)];
    const cx = Math.min(Math.max(baseCx + dx, w / 2 + 8), cw - w / 2 - 8);
    const top = Math.min(Math.max(baseTop + dy, 8), canvasH - h - 8);
    setOffsets((current) => ({ ...current, [node.id]: { dx: cx - baseCx, dy: top - baseTop } }));
  };

  const onPointerUp = (node: StepNode) => () => {
    const d = drag.current;
    if (d?.id === node.id) {
      /* a real drag shouldn't also toggle selection */
      if (d.moved) setTimeout(() => (drag.current = null), 0);
      else drag.current = null;
    }
  };

  const wasDragged = () => drag.current?.moved === true;

  const isLit = (edge: { from: string; to: string }) =>
    selected === edge.from || selected === edge.to;

  return (
    <div
      ref={canvasRef}
      className="relative w-full select-none overflow-hidden rounded-card bg-page shadow-hairline"
      style={{
        height: canvasH,
        backgroundImage: "radial-gradient(var(--line-strong) 1px, transparent 1.25px)",
        backgroundSize: "22px 22px",
        backgroundPosition: "center",
      }}
    >
      {/* connectors */}
      <svg width={cw} height={canvasH} className="pointer-events-none absolute inset-0">
        {EDGES.map((edge) => (
          <path
            key={`${edge.from}-${edge.to}`}
            d={bezier(edge)}
            fill="none"
            stroke={isLit(edge) ? "var(--accent)" : "var(--line-strong)"}
            strokeWidth="1.25"
            className="transition-[stroke] duration-150"
          />
        ))}
      </svg>

      {/* nodes */}
      {NODES.map((node) => {
        const { w, cx, top } = place(node);
        const active = selected === node.id;
        return (
          <div
            key={node.id}
            ref={(el) => {
              if (el) nodeRefs.current.set(node.id, el);
              else nodeRefs.current.delete(node.id);
            }}
            onPointerDown={onPointerDown(node)}
            onPointerMove={onPointerMove(node)}
            onPointerUp={onPointerUp(node)}
            className="absolute flex -translate-x-1/2 touch-none flex-col items-start gap-1.5"
            style={{ left: cx, top, width: w, zIndex: drag.current?.id === node.id ? 2 : 1 }}
          >
            {node.kind && (
              <span
                className="inline-flex h-6 items-center rounded-[6px] px-2 text-[11.5px] font-medium"
                style={{
                  background: mix(node.kind.hue, 14, "var(--page)"),
                  color: mix(node.kind.hue, 80, "var(--ink)"),
                }}
              >
                {node.kind.label}
              </span>
            )}
            {node.condition ? (
              <div className="w-full rounded-card bg-surface shadow-card transition-shadow duration-150 hover:shadow-raised">
                <ConditionBody />
              </div>
            ) : (
              <button
                type="button"
                onClick={() => {
                  if (wasDragged()) return;
                  setSelected(active ? null : node.id);
                }}
                aria-pressed={active}
                className={`w-full cursor-pointer rounded-card bg-surface text-left outline-none
                  transition-shadow duration-150 focus-visible:shadow-[0_0_0_1.5px_var(--accent)]
                  ${
                    active
                      ? "shadow-[0_0_0_1.5px_var(--accent),0_2px_10px_rgba(0,0,0,0.045)]"
                      : "shadow-card hover:shadow-raised"
                  }`}
              >
                <StepBody node={node} />
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}
