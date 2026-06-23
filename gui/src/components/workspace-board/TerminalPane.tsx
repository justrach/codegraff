import { useCallback, useEffect, useRef, useState } from "react";
import type { IDockviewPanelProps } from "dockview-react";
import "@wterm/dom/css";

import { PaneSurface } from "@/components/ui/PaneSurface";
import { useTerminalSession } from "./hooks/useTerminalSession";
import type { TerminalPaneParams } from "./types/layout";

export function TerminalPane({
  params,
}: IDockviewPanelProps<TerminalPaneParams>) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const copiedPopupTimerRef = useRef<number | null>(null);
  const [isCopiedPopupVisible, setIsCopiedPopupVisible] = useState(false);

  const showCopiedPopup = useCallback(() => {
    setIsCopiedPopupVisible(true);

    if (copiedPopupTimerRef.current != null) {
      window.clearTimeout(copiedPopupTimerRef.current);
    }

    copiedPopupTimerRef.current = window.setTimeout(() => {
      setIsCopiedPopupVisible(false);
      copiedPopupTimerRef.current = null;
    }, 1500);
  }, []);

  useEffect(() => {
    return () => {
      if (copiedPopupTimerRef.current != null) {
        window.clearTimeout(copiedPopupTimerRef.current);
      }
    };
  }, []);

  const { status } = useTerminalSession(params, containerRef, {
    onSelectionCopied: showCopiedPopup,
  });

  return (
    <PaneSurface className="terminal-pane-shell relative">
      <div className="relative flex min-h-0 flex-1">
        <div className="h-full min-h-0 w-full min-w-0 px-3 py-2.5">
          <div ref={containerRef} className="h-full min-h-0 w-full min-w-0" />
        </div>
        {status != null ? (
          <div className="pointer-events-none absolute inset-x-4 top-4 rounded-md border border-border bg-popover px-3 py-2 text-xs text-popover-foreground shadow-lg dark:bg-popover">
            {status.message}
          </div>
        ) : null}
        {isCopiedPopupVisible ? (
          <div className="pointer-events-none absolute inset-x-4 bottom-4 flex justify-center">
            <div className="rounded-md border border-border bg-popover px-3 py-1.5 text-xs text-popover-foreground shadow-lg dark:bg-popover">
              Copied to clipboard
            </div>
          </div>
        ) : null}
      </div>
    </PaneSurface>
  );
}
