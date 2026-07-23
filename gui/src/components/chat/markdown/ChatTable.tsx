import { useLayoutEffect, useRef, useState } from "react";
import type { ReactNode } from "react";

import { cn } from "@/utils/cn";
import {
  chatTableLayoutFor,
  type ChatTableLayout,
} from "./chatTableLayout";
import type { TableAlign } from "./types";

interface ChatTableProps {
  header: ReactNode[];
  align: TableAlign[];
  rows: ReactNode[][];
  /** Test/SSR escape hatch; normally decided by measuring the container. */
  forceLayout?: ChatTableLayout;
}

/**
 * Adaptive chat table: a regular grid table when the pane is wide enough,
 * collapsing to one record card per row (`Label: value` lines) when it isn't.
 * Mirrors the TUI renderer's box-drawing table and its narrow record fallback
 * (src/repl.zig renderTable/renderRecords), so both surfaces degrade the same
 * way. Chat tiles resize independently of the window (dockview), so the
 * decision measures the container, not the viewport.
 */
export function ChatTable({ header, align, rows, forceLayout }: ChatTableProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [measured, setMeasured] = useState<ChatTableLayout>("table");
  const layout = forceLayout ?? measured;

  useLayoutEffect(() => {
    if (forceLayout || typeof ResizeObserver === "undefined") return;
    const el = containerRef.current;
    if (!el) return;
    const update = () =>
      setMeasured(chatTableLayoutFor(el.clientWidth, header.length));
    update();
    const observer = new ResizeObserver(update);
    observer.observe(el);
    return () => observer.disconnect();
  }, [forceLayout, header.length]);

  const alignClass = (a: TableAlign) =>
    a === "center" ? "text-center" : a === "right" ? "text-right" : undefined;

  if (layout === "records") {
    return (
      <div
        ref={containerRef}
        className="flex max-w-full flex-col divide-y divide-border/70 rounded-md border border-border/70"
      >
        {rows.map((row, rowIndex) => (
          <dl key={rowIndex} className="m-0 flex flex-col gap-1 px-3 py-2 text-sm">
            {row.map((cell, cellIndex) => (
              <div key={cellIndex} className="flex min-w-0 gap-2">
                <dt className="shrink-0 pt-px text-xs font-medium uppercase tracking-normal text-muted-foreground">
                  {header[cellIndex]}
                </dt>
                <dd className="m-0 min-w-0 break-words">{cell}</dd>
              </div>
            ))}
          </dl>
        ))}
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className="max-w-full overflow-x-auto rounded-md border border-border/70"
    >
      <table className="w-full border-collapse text-left text-sm">
        <thead>
          <tr>
            {header.map((cell, index) => (
              <th
                key={index}
                className={cn(
                  "bg-muted/55 px-3 py-2 text-xs font-medium uppercase tracking-normal text-muted-foreground",
                  alignClass(align[index]),
                )}
              >
                {cell}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, cellIndex) => (
                <td
                  key={cellIndex}
                  className={cn(
                    "border-t border-border/70 px-3 py-2 align-top",
                    alignClass(align[cellIndex]),
                  )}
                >
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
