import { useEffect, useRef, useState } from "react";
import type { IDockviewPanelProps } from "dockview-react";
import { XIcon } from "lucide-react";
import "@wterm/dom/css";

import { Button } from "@/components/ui/Button";
import { PaneSurface } from "@/components/ui/PaneSurface";
import { useTerminalSession } from "./hooks/useTerminalSession";
import type { TerminalPaneParams } from "./types/layout";

const AUTO_COPY_DEBOUNCE_MS = 120;
const AUTO_COPY_TOAST_MS = 2400;

function getSelectionTextWithin(container: HTMLElement): string | null {
  const selection = window.getSelection();
  if (selection == null || selection.isCollapsed || selection.rangeCount === 0) {
    return null;
  }

  const range = selection.getRangeAt(0);
  const commonAncestor = range.commonAncestorContainer;
  if (!container.contains(commonAncestor)) {
    return null;
  }

  const text = selection.toString().trimEnd();
  return text.length === 0 ? null : text;
}

export function TerminalPane({
  params,
}: IDockviewPanelProps<TerminalPaneParams>) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const lastCopiedTextRef = useRef("");
  const copyDebounceTimerRef = useRef<number | null>(null);
  const copyRequestSeqRef = useRef(0);
  const copyWriteChainRef = useRef<Promise<void>>(Promise.resolve());
  const dismissToastTimerRef = useRef<number | null>(null);
  const [copyToast, setCopyToast] = useState<string | null>(null);
  const { status } = useTerminalSession(params, containerRef);

  useEffect(() => {
    const clearDismissTimer = () => {
      if (dismissToastTimerRef.current != null) {
        window.clearTimeout(dismissToastTimerRef.current);
        dismissToastTimerRef.current = null;
      }
    };

    const showToast = (message: string) => {
      clearDismissTimer();
      setCopyToast(message);
      dismissToastTimerRef.current = window.setTimeout(() => {
        setCopyToast(null);
        dismissToastTimerRef.current = null;
      }, AUTO_COPY_TOAST_MS);
    };

    const clearCopyDebounceTimer = () => {
      if (copyDebounceTimerRef.current != null) {
        window.clearTimeout(copyDebounceTimerRef.current);
        copyDebounceTimerRef.current = null;
      }
    };

    const copySelectedText = (selectedText: string, requestSeq: number) => {
      if (selectedText === lastCopiedTextRef.current) {
        return;
      }

      lastCopiedTextRef.current = selectedText;
      if (navigator.clipboard == null) {
        showToast("Select copied text manually");
        return;
      }

      copyWriteChainRef.current = copyWriteChainRef.current
        .catch(() => undefined)
        .then(async () => {
          if (copyRequestSeqRef.current !== requestSeq) {
            return;
          }
          await navigator.clipboard.writeText(selectedText);
          if (copyRequestSeqRef.current === requestSeq) {
            showToast("Copied terminal selection");
          }
        })
        .catch(() => {
          if (copyRequestSeqRef.current === requestSeq) {
            showToast("Select copied text manually");
          }
        });
      void copyWriteChainRef.current;
    };

    const handleSelectionChange = () => {
      const container = containerRef.current;
      if (container == null) {
        return;
      }

      const selectedText = getSelectionTextWithin(container);
      clearCopyDebounceTimer();
      const requestSeq = copyRequestSeqRef.current + 1;
      copyRequestSeqRef.current = requestSeq;
      if (selectedText == null) {
        return;
      }

      copyDebounceTimerRef.current = window.setTimeout(() => {
        copyDebounceTimerRef.current = null;
        copySelectedText(selectedText, requestSeq);
      }, AUTO_COPY_DEBOUNCE_MS);
    };

    document.addEventListener("selectionchange", handleSelectionChange);
    return () => {
      document.removeEventListener("selectionchange", handleSelectionChange);
      clearCopyDebounceTimer();
      clearDismissTimer();
    };
  }, []);

  function dismissCopyToast() {
    if (dismissToastTimerRef.current != null) {
      window.clearTimeout(dismissToastTimerRef.current);
      dismissToastTimerRef.current = null;
    }
    setCopyToast(null);
  }

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
        {copyToast != null ? (
          <div className="absolute right-4 top-4 flex items-center gap-2 rounded-md border border-border bg-popover px-3 py-2 text-xs text-popover-foreground shadow-lg dark:bg-popover">
            <span>{copyToast}</span>
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label="Dismiss copied selection notice"
              onClick={dismissCopyToast}
            >
              <XIcon />
            </Button>
          </div>
        ) : null}
      </div>
    </PaneSurface>
  );
}
