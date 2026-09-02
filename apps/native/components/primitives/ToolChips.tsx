"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

/* ─────────────────────────────────────────────────────────
 * TOOL CHIPS
 * An agent run as compact rows: tool calls with inline
 * chips, then file-diff chips summarizing the edits.
 * Hover a row to reveal its chevron; every row expands
 * to show what the tool actually did.
 * ───────────────────────────────────────────────────────── */

const STEP_MS = 700;

const Icons: Record<string, React.ReactNode> = {
  think: <path d="M12 2l2.4 7.2L22 12l-7.6 2.8L12 22l-2.4-7.2L2 12l7.6-2.8z" />,
  write: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 3a2.8 2.8 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5z" /></g>,
  run: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 17l6-5-6-5M12 19h8" /></g>,
  read: <g fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" /><path d="M14 2v6h6" /></g>,
};

type DetailLine = { text: string; tone?: "add" };

const ROWS: { icon: string; label: string; chip: string; mono: boolean; detailMono: boolean; detail: DetailLine[] }[] = [
  {
    icon: "think", label: "Thinking", chip: "Planning the churn schedule…", mono: false, detailMono: false,
    detail: [
      { text: "Weekend demand carries pistachio, so it churns first." },
      { text: "Batch capacity leaves two evening freezer windows." },
    ],
  },
  {
    icon: "write", label: "Write 204 lines", chip: "ChurnSchedule.tsx", mono: true, detailMono: true,
    detail: [
      { text: "+ const windows = slots.filter((s) => s.temp <= -12)", tone: "add" },
      { text: "+ return schedule(windows, { hero: \"pistachio\" })", tone: "add" },
    ],
  },
  {
    icon: "run", label: "Rebuild and verify", chip: "npm run freeze", mono: true, detailMono: true,
    detail: [
      { text: "✓ built in 1.2s" },
      { text: "✓ 34 checks passed" },
    ],
  },
  {
    icon: "read", label: "Read image", chip: "flavor-chart.png", mono: true, detailMono: false,
    detail: [
      { text: "1280 × 720 · line chart, three summers." },
      { text: "Mint chip trends up 12% through July." },
    ],
  },
];

const DIFFS = [
  { file: "flavors.css", add: 13, del: 0 },
  { file: "ChurnSchedule.tsx", add: 74, del: 41 },
  { file: "menu.ts", add: 8, del: 2 },
];

/* hovering a file chip opens its diff — green added, red removed */
type DiffLine = { text: string; tone: "add" | "del" | "ctx" };
const DIFF_LINES: Record<string, DiffLine[]> = {
  "flavors.css": [
    { text: ".scoop-card {", tone: "ctx" },
    { text: "  gap: 14px;", tone: "del" },
    { text: "  gap: 12px;", tone: "add" },
    { text: "  container-type: inline-size;", tone: "add" },
    { text: "}", tone: "ctx" },
  ],
  "ChurnSchedule.tsx": [
    { text: "const slots = coldSlots(week);", tone: "ctx" },
    { text: "const windows = slots;", tone: "del" },
    { text: "const windows = slots.filter(", tone: "add" },
    { text: "  (s) => s.temp <= -12,", tone: "add" },
    { text: ");", tone: "add" },
  ],
  "menu.ts": [
    { text: "export const hero = \"mint-chip\";", tone: "del" },
    { text: "export const hero = \"pistachio\";", tone: "add" },
  ],
};

export type LiveToolRow = {
  id?: string;
  icon: string;
  label: string;
  chip: string;
  mono?: boolean;
  detailMono?: boolean;
  detail: { text: string; tone?: "add" }[];
  /** Workspace file this call touched; makes the chip a jump target. */
  path?: string;
  /** Live call state — running rows get a spinner so the turn visibly moves. */
  status?: "running" | "ok" | "error";
  startedAt?: number;
  elapsedMs?: number;
};

function formatDuration(ms: number): string | null {
  if (ms < 1000) return null;
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  return `${Math.floor(s / 60)}m ${s % 60}s`;
}

export type LiveDiff = {
  file: string;
  add: number;
  del: number;
  lines?: { text: string; tone: "add" | "del" | "ctx" }[];
};

export default function ToolChips({
  rows: liveRows,
  diffs: liveDiffs,
  onOpenPath,
}: {
  rows?: LiveToolRow[];
  diffs?: LiveDiff[];
  /** Open a touched file in the harness's files pane. */
  onOpenPath?: (path: string) => void;
} = {}) {
  const live = liveRows !== undefined;
  const rows = live ? liveRows : ROWS;
  const diffs = live ? (liveDiffs ?? []) : DIFFS;
  const diffLines: Record<string, { text: string; tone: "add" | "del" | "ctx" }[]> = live
    ? Object.fromEntries((liveDiffs ?? []).map((d) => [d.file, d.lines ?? []]))
    : DIFF_LINES;
  const [step, setStep] = useState(0);
  const [open, setOpen] = useState(true);
  const userToggled = useRef(false);
  /* tick once a second while any live row runs, so its timer counts up */
  const [, setClock] = useState(0);
  const anyRunning = live && rows.some((r) => "status" in r && r.status === "running");
  useEffect(() => {
    if (!anyRunning) return;
    const t = setInterval(() => setClock((c) => c + 1), 1000);
    return () => clearInterval(t);
  }, [anyRunning]);
  /* A batch of reads should not be a wall sitting on the answer. Expand
   * while something is running so the live call is visible; fold the rest
   * into the summary once they settle — unless the reader opened it. */
  useEffect(() => {
    if (!live || userToggled.current) return;
    if (anyRunning) setOpen(true);
    else if (rows.length > 1) setOpen(false);
  }, [live, anyRunning, rows.length]);
  const showHeader = !live || rows.length > 1;
  const [openRows, setOpenRows] = useState<Set<string>>(new Set());
  /* Rendered in a body portal so animated/translated reply wrappers cannot
   * redefine the fixed-position coordinate system. */
  const [preview, setPreview] = useState<{
    file: string;
    x: number;
    top?: number;
    bottom?: number;
  } | null>(null);
  const openPreview = (file: string) => (event: React.SyntheticEvent) => {
    const rect = (event.currentTarget as Element).closest("[data-diffchip]")!.getBoundingClientRect();
    const previewHeight = 38 + (diffLines[file]?.length ?? 0) * 19;
    const fitsBelow = rect.bottom + 6 + previewHeight <= window.innerHeight - 12;
    setPreview({
      file,
      x: Math.max(12, Math.min(rect.left, window.innerWidth - 300)),
      ...(fitsBelow
        ? { top: rect.bottom + 6 }
        : { bottom: window.innerHeight - rect.top + 6 }),
    });
  };
  const closePreview = (file: string) => () =>
    setPreview((current) => (current?.file === file ? null : current));
  const total = live ? rows.length : ROWS.length + 1; // rows, then diff chips

  useEffect(() => {
    if (live) return;
    if (step >= total) return;
    const t = setTimeout(() => setStep((s) => s + 1), STEP_MS);
    return () => clearTimeout(t);
  }, [step, total, live]);

  const toggleRow = (id: string) =>
    setOpenRows((current) => {
      const next = new Set(current);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });

  return (
    <div className={live ? "w-full pb-1" : "min-h-[220px] w-full max-w-80 pb-1"}>
      {/* collapsed run header */}
      {showHeader && (
      <button
        type="button"
        aria-expanded={open}
        onClick={() => {
          userToggled.current = true;
          setOpen((current) => !current);
        }}
        className="-mx-1.5 flex w-fit items-center gap-1.5 rounded-control px-1.5 py-1 text-[12.5px] text-ink-2 transition-colors duration-100 hover:bg-hover-2"
      >
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" className="transition-transform duration-200" style={{ transform: open ? "rotate(0deg)" : "rotate(-90deg)" }}>
          <path d="M6 9l6 6 6-6" />
        </svg>
        <span className="tabular-nums">
          {live
            ? (() => {
                const counts: Record<string, number> = {};
                for (const row of rows) counts[row.icon] = (counts[row.icon] ?? 0) + 1;
                const parts: string[] = [];
                if (counts.read) parts.push(`Explored ${counts.read}`);
                if (counts.write) parts.push(`Edited ${counts.write}`);
                if (counts.run) parts.push(`Ran ${counts.run}`);
                const other = rows.length - (counts.read ?? 0) - (counts.write ?? 0) - (counts.run ?? 0);
                if (other > 0) parts.push(`${other} other`);
                const liveN = rows.filter((r) => "status" in r && r.status === "running").length;
                if (liveN) parts.push(liveN === 1 ? "running" : `${liveN} running`);
                return parts.join(" · ") || `${rows.length} steps`;
              })()
            : "4 tool calls, 2 messages"}
        </span>
      </button>
      )}

      {/* tool call rows */}
      <div className="grid transition-[grid-template-rows,opacity] duration-300" style={{ gridTemplateRows: !showHeader || open ? "1fr" : "0fr", opacity: !showHeader || open ? 1 : 0 }}>
        {/* -mx-1 + px-1.5 keeps content at the same x while giving the
            row hover pills room inside this overflow-hidden clip box */}
        <div className="-mx-1 overflow-hidden px-1.5 pb-1">
        <div className="mt-1.5 flex flex-col gap-1">
          {(live ? rows : rows.slice(0, step)).map((row, i) => {
            const rowKey = "id" in row && row.id ? row.id : `${row.label}-${i}`;
            const rowOpen = openRows.has(rowKey);
            return (
            <div key={rowKey} style={live ? undefined : { animation: "fade-up 300ms cubic-bezier(0.23,1,0.32,1) both" }}>
              <button
                type="button"
                aria-expanded={rowOpen}
                onClick={() => toggleRow(rowKey)}
                className="group/row -mx-[3px] flex h-7 w-[calc(100%+6px)] min-w-0 items-center gap-2 rounded-control px-[3px] text-left transition-colors duration-100 hover:bg-hover-2"
              >
                <span className="relative flex size-4 shrink-0 items-center justify-center text-ink-3">
                  {"status" in row && row.status === "running" ? (
                    <span
                      className={`size-3 rounded-full border-[1.5px] border-line-strong border-t-ink-2 transition-opacity duration-100 group-hover/row:opacity-0 ${rowOpen ? "opacity-0" : ""}`}
                      style={{ animation: "spin 700ms linear infinite" }}
                    />
                  ) : (
                  <svg
                    width="13" height="13" viewBox="0 0 24 24" fill={row.icon === "think" ? "currentColor" : "none"} stroke="currentColor"
                    className={`transition-opacity duration-100 group-hover/row:opacity-0 ${rowOpen ? "opacity-0" : ""} ${"status" in row && row.status === "error" ? "text-red" : ""}`}
                  >
                    {Icons[row.icon]}
                  </svg>
                  )}
                  <svg
                    width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"
                    className={`absolute transition-[opacity,transform] duration-150 group-hover/row:opacity-100 ${rowOpen ? "opacity-100" : "opacity-0"}`}
                    style={{ transform: rowOpen ? "rotate(0deg)" : "rotate(-90deg)" }}
                  >
                    <path d="M6 9l6 6 6-6" />
                  </svg>
                </span>
                {row.chip ? (
                  <>
                    <span className="shrink-0 text-[11.5px] text-ink-3">{row.label}</span>
                    <span
                      onClick={
                        onOpenPath && "path" in row && row.path
                          ? (event) => {
                              event.stopPropagation();
                              onOpenPath(row.path!);
                            }
                          : undefined
                      }
                      title={onOpenPath && "path" in row && row.path ? `Open ${row.path}` : row.chip}
                      className={`inline-flex h-5.5 min-w-0 max-w-fit flex-1 items-center truncate rounded-chip bg-field px-1.5
                        text-[12px] text-ink shadow-hairline transition-colors duration-100 hover:bg-hover-2
                        ${row.mono ? "font-mono" : ""} ${onOpenPath && "path" in row && row.path ? "cursor-pointer" : ""}`}
                    >
                      {row.chip}
                    </span>
                  </>
                ) : (
                  <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-ink">{row.label}</span>
                )}
                {"status" in row && (() => {
                  const label =
                    row.status === "running" && row.startedAt
                      ? formatDuration(Date.now() - row.startedAt)
                      : row.elapsedMs !== undefined
                        ? formatDuration(row.elapsedMs)
                        : null;
                  return label ? (
                    <span className="shrink-0 pl-2 font-mono text-[10.5px] text-ink-3 tabular-nums">{label}</span>
                  ) : null;
                })()}
              </button>

              {/* expanded detail */}
              <div
                className="grid transition-[grid-template-rows,opacity] duration-300"
                style={{ gridTemplateRows: rowOpen ? "1fr" : "0fr", opacity: rowOpen ? 1 : 0, transitionTimingFunction: "cubic-bezier(0.23, 1, 0.32, 1)" }}
              >
                <div className="min-h-0 overflow-hidden">
                  <div className="mt-0.5 mb-1 ml-2 flex flex-col gap-0.5 border-l border-line py-0.5 pl-3.5">
                    {row.detail.map((line, lineIdx) => (
                      <span
                        key={`${lineIdx}:${line.text}`}
                        className={`truncate text-[11.5px] leading-[1.6] ${row.detailMono ? "font-mono" : ""} ${line.tone === "add" ? "text-green" : "text-ink-2"}`}
                      >
                        {line.text}
                      </span>
                    ))}
                  </div>
                </div>
              </div>
            </div>
            );
          })}
        </div>

      {/* file-diff chips */}
      {(live ? diffs.length > 0 : step >= total) && (
        <div className="mt-2.5 flex max-w-full flex-wrap gap-1.5 border-t border-line pt-2.5">
          {diffs.map((d, i) => (
            <span
              key={d.file}
              data-diffchip
              className="relative"
              onMouseEnter={openPreview(d.file)}
              onMouseLeave={closePreview(d.file)}
            >
              <button
                type="button"
                aria-expanded={preview?.file === d.file}
                aria-label={`Show diff for ${d.file}`}
                onFocus={openPreview(d.file)}
                onBlur={closePreview(d.file)}
                className="inline-flex h-7 max-w-full items-center gap-1.5 rounded-chip
                  bg-surface px-2 font-mono text-[11.5px] text-ink shadow-btn
                  transition-colors duration-100 hover:bg-hover"
                style={{ animation: `pop-in 250ms cubic-bezier(0.23,1,0.32,1) ${i * 80}ms both` }}
              >
                <span className="min-w-0 truncate">{d.file}</span>
                <span className="shrink-0 text-green tabular-nums">+{d.add}</span>
                {d.del > 0 && <span className="shrink-0 text-red tabular-nums">−{d.del}</span>}
              </button>

            </span>
          ))}
          <button
            type="button"
            className="inline-flex h-7 items-center rounded-chip px-1.5 font-mono text-[11.5px] text-ink-3
              underline decoration-transparent underline-offset-2 transition-colors duration-100
              hover:text-ink-2 hover:decoration-current"
            style={{ animation: `fade-in 300ms ease-out ${DIFFS.length * 80}ms both` }}
          >
            {live ? `${diffs.length} files` : "+2 more"}
          </button>
        </div>
      )}
        </div>
      </div>
      {preview && typeof document !== "undefined" && createPortal(
        <div
          className="fixed z-50 w-72 overflow-hidden rounded-[10px] bg-surface shadow-overlay"
          style={{
            left: preview.x,
            top: preview.top,
            bottom: preview.bottom,
            animation: "pop-in 160ms cubic-bezier(0.23,1,0.32,1) both",
            transformOrigin: preview.top === undefined ? "bottom left" : "top left",
          }}
        >
          <div className="flex items-center justify-between border-b border-line px-2.5 py-1.5 font-mono text-[11px]">
            <span className="min-w-0 truncate text-ink-2">{preview.file}</span>
            <span className="shrink-0 tabular-nums">
              <span className="text-green">+{diffs.find((diff) => diff.file === preview.file)?.add}</span>
              {(diffs.find((diff) => diff.file === preview.file)?.del ?? 0) > 0 && (
                <span className="text-red"> −{diffs.find((diff) => diff.file === preview.file)?.del}</span>
              )}
            </span>
          </div>
          <div className="py-1 font-mono text-[11px] leading-[1.8]">
            {(diffLines[preview.file] ?? []).map((line, index) => (
              <div
                key={index}
                className={`flex gap-2 px-2.5 whitespace-pre ${
                  line.tone === "add"
                    ? "bg-green-tint text-green"
                    : line.tone === "del"
                      ? "bg-red-tint text-red"
                      : "text-ink-2"
                }`}
              >
                <span className="w-3 shrink-0 select-none">{line.tone === "add" ? "+" : line.tone === "del" ? "−" : " "}</span>
                <span className="min-w-0 truncate">{line.text}</span>
              </div>
            ))}
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
