"use client";

import { useState, type SyntheticEvent } from "react";
import { createPortal } from "react-dom";
import { DIFF_CHIP_CAP, diffChipLabels, meaningfulDiffStat } from "@/lib/diff-chip-label";

type DiffLine = { text: string; tone: "add" | "del" | "ctx" };

export type DiffChipModel = {
  file: string;
  add: number;
  del: number;
  lines?: DiffLine[];
};

/**
 * What a turn changed, without a wall of pills. A few files stay as short
 * chips. A long list folds behind `+N` — the reader opens it, the transcript
 * does not.
 */
export default function DiffChipStrip({
  diffs,
  onOpenPath,
}: {
  diffs: DiffChipModel[];
  onOpenPath?: (path: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const [preview, setPreview] = useState<{ file: string; x: number; top?: number; bottom?: number } | null>(null);
  if (diffs.length === 0) return null;
  const labels = diffChipLabels(diffs.map((diff) => diff.file));
  const folded = !expanded && diffs.length > DIFF_CHIP_CAP;
  const shown = folded ? diffs.slice(0, DIFF_CHIP_CAP) : diffs;
  const linesOf = (file: string) => diffs.find((diff) => diff.file === file)?.lines ?? [];

  const openPreview = (file: string) => (event: SyntheticEvent) => {
    const rect = (event.currentTarget as Element).closest("[data-diffchip]")!.getBoundingClientRect();
    const previewHeight = 38 + linesOf(file).length * 19;
    const fitsBelow = rect.bottom + 6 + previewHeight <= window.innerHeight - 12;
    setPreview({
      file,
      x: Math.max(12, Math.min(rect.left, window.innerWidth - 300)),
      ...(fitsBelow ? { top: rect.bottom + 6 } : { bottom: window.innerHeight - rect.top + 6 }),
    });
  };
  const closePreview = (file: string) => () =>
    setPreview((current) => (current?.file === file ? null : current));

  return (
    <div data-diff-strip className="mt-2 flex max-w-full flex-wrap items-center gap-1.5">
      <div className={expanded && diffs.length > DIFF_CHIP_CAP ? "flex max-h-[min(28vh,200px)] min-w-0 flex-1 flex-wrap gap-1.5 overflow-auto overscroll-contain" : "contents"}>
        {shown.map((diff) => {
          const index = diffs.indexOf(diff);
          const label = labels[index] ?? diff.file;
          const showStat = meaningfulDiffStat(diff.add, diff.del);
          return (
            <span
              key={diff.file}
              data-diffchip
              className="relative max-w-full"
              onMouseEnter={openPreview(diff.file)}
              onMouseLeave={closePreview(diff.file)}
            >
              <button
                type="button"
                aria-expanded={preview?.file === diff.file}
                aria-label={`Show diff for ${diff.file}`}
                title={diff.file}
                onFocus={openPreview(diff.file)}
                onBlur={closePreview(diff.file)}
                onClick={onOpenPath ? () => onOpenPath(diff.file) : undefined}
                className="inline-flex h-7 max-w-full items-center gap-1.5 rounded-chip bg-surface px-2 font-mono text-[11.5px] text-ink shadow-btn transition-colors duration-100 hover:bg-hover"
              >
                <span data-diff-label className="min-w-0 truncate">{label}</span>
                {showStat && (
                  <span data-diff-stat className="shrink-0 tabular-nums">
                    <span className="text-green">+{diff.add}</span>
                    {diff.del > 0 && <span className="text-red"> −{diff.del}</span>}
                  </span>
                )}
              </button>
            </span>
          );
        })}
      </div>
      {diffs.length > DIFF_CHIP_CAP && (
        <button
          type="button"
          data-diff-more
          aria-expanded={expanded}
          onClick={() => setExpanded((current) => !current)}
          className="inline-flex h-7 items-center rounded-full px-2 text-[12px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink-2"
        >
          {expanded ? "Show less" : `+${diffs.length - DIFF_CHIP_CAP}`}
        </button>
      )}
      {preview && typeof document !== "undefined" && createPortal(
        <div
          className="fixed z-50 w-72 overflow-hidden rounded-card bg-surface shadow-overlay"
          style={{
            left: preview.x,
            top: preview.top,
            bottom: preview.bottom,
            transformOrigin: preview.top === undefined ? "bottom left" : "top left",
          }}
        >
          <div className="flex items-center justify-between border-b border-line px-2.5 py-1.5 font-mono text-[11px]">
            <span className="min-w-0 truncate text-ink-2">{preview.file}</span>
            {(() => {
              const diff = diffs.find((item) => item.file === preview.file);
              if (!diff || !meaningfulDiffStat(diff.add, diff.del)) return null;
              return (
                <span className="shrink-0 tabular-nums">
                  <span className="text-green">+{diff.add}</span>
                  {diff.del > 0 && <span className="text-red"> −{diff.del}</span>}
                </span>
              );
            })()}
          </div>
          <div className="py-1 font-mono text-[11px] leading-[1.8]">
            {linesOf(preview.file).map((line, index) => (
              <div
                key={index}
                className={`flex gap-2 px-2.5 whitespace-pre ${
                  line.tone === "add" ? "bg-green-tint text-green" : line.tone === "del" ? "bg-red-tint text-red" : "text-ink-2"
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
