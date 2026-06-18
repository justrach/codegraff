import { useEffect, useRef, useState, type ReactNode } from "react";
import type { DockviewPanelApi } from "dockview-react";

import { cn } from "@/utils/cn";

import { PANE_CLOSE_REQUEST_EVENT_NAME } from "./layout";

export type PaneSlideDirection = "right" | "bottom";

interface AuxiliaryPaneShellProps {
  api: DockviewPanelApi;
  paneId: string;
  direction: PaneSlideDirection;
  children: ReactNode;
}

const ENTER_ANIMATION: Record<PaneSlideDirection, string> = {
  right: "slide-in-from-right-4",
  bottom: "slide-in-from-bottom-4",
};

const EXIT_ANIMATION: Record<PaneSlideDirection, string> = {
  right: "slide-out-to-right-4",
  bottom: "slide-out-to-bottom-4",
};

// Fallback close delay (ms) used if the exit animation never reports completion
// (e.g. under `prefers-reduced-motion`, where the animation may not run).
const EXIT_FALLBACK_MS = 220;

/**
 * Wraps an auxiliary dock pane (preview / changes / terminal) so it slides in on
 * mount and slides out on close. Side panes slide along the x-axis; the bottom
 * terminal slides along the y-axis. Closing is driven by a window event
 * ({@link PANE_CLOSE_REQUEST_EVENT_NAME}) so the pane can animate out before
 * `api.close()` removes it from the layout.
 */
export function AuxiliaryPaneShell({
  api,
  paneId,
  direction,
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
        "h-full w-full",
        closing
          ? cn(
              "animate-out fade-out-0 fill-mode-forwards duration-150",
              EXIT_ANIMATION[direction],
            )
          : cn("animate-in fade-in-0 duration-200", ENTER_ANIMATION[direction]),
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
