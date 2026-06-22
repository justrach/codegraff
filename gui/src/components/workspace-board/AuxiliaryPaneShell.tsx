import { useEffect, useRef, useState, type ReactNode } from "react";
import type { DockviewPanelApi } from "dockview-react";

import { cn } from "@/utils/cn";

import { PANE_CLOSE_REQUEST_EVENT_NAME } from "./layout";

interface AuxiliaryPaneShellProps {
  api: DockviewPanelApi;
  paneId: string;
  children: ReactNode;
}

// Fallback close delay (ms) used if the exit animation never reports completion
// (e.g. under `prefers-reduced-motion`, where the animation may not run). Kept a
// touch above the exit fade duration in index.css.
const EXIT_FALLBACK_MS = 220;

/**
 * Wraps an auxiliary dock pane (preview / changes / terminal) so its content
 * crossfades in on mount and out on close, while the surrounding panes glide to
 * their new size (driven from ChatTile via paneResizeAnimation.ts). Closing is
 * driven by a window event ({@link PANE_CLOSE_REQUEST_EVENT_NAME}) so the pane can
 * fade out before `api.close()` removes it from the layout.
 */
export function AuxiliaryPaneShell({
  api,
  paneId,
  children,
}: AuxiliaryPaneShellProps) {
  const [closing, setClosing] = useState(false);
  const closedRef = useRef(false);

  function closeOnce() {
    if (closedRef.current) {
      return;
    }
    closedRef.current = true;
    api.close();
  }

  useEffect(() => {
    function handleCloseRequest(event: Event) {
      const detail = (event as CustomEvent<{ paneId?: string }>).detail;
      if (detail?.paneId === paneId) {
        setClosing(true);
      }
    }

    window.addEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
    return () => {
      window.removeEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
    };
  }, [paneId]);

  useEffect(() => {
    if (!closing) {
      return;
    }
    const timer = window.setTimeout(closeOnce, EXIT_FALLBACK_MS);
    return () => {
      window.clearTimeout(timer);
    };
    // closeOnce is idempotent; we intentionally only re-run when `closing` flips.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [closing]);

  return (
    <div
      className={cn(
        "h-full w-full overflow-hidden",
        closing ? "cg-pane-exit" : "cg-pane-enter",
      )}
      onAnimationEnd={(event) => {
        if (event.target !== event.currentTarget) {
          return;
        }
        if (closing) {
          closeOnce();
        }
      }}
    >
      {children}
    </div>
  );
}
