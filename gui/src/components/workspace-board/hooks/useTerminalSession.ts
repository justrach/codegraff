import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
} from "react";
import { WTerm } from "@wterm/dom";

import * as desktopClient from "@/services/desktop/client";

import {
  DEFAULT_TERMINAL_COLS,
  DEFAULT_TERMINAL_ROWS,
  INITIAL_RESIZE_OBSERVER_DELAY_MS,
  TERMINAL_CONNECTING_MESSAGE,
} from "../constants/terminal";
import {
  createTerminalSessionId,
  TERMINAL_RESTART_EVENT_NAME,
} from "../layout";
import type { TerminalPaneParams } from "../types/layout";
import type { TerminalGridSize, TerminalStatus } from "../types/workspaceBoard";
import {
  measureTerminalGridSize,
  normalizeTerminalSize,
  waitForStableTerminalSize,
} from "../utils/terminal";

type UseTerminalSessionOptions = {
  onSelectionCopied?: () => void;
};

export function useTerminalSession(
  params: TerminalPaneParams,
  containerRef: RefObject<HTMLDivElement | null>,
  options: UseTerminalSessionOptions = {},
) {
  const terminalRef = useRef<WTerm | null>(null);
  const openedRef = useRef(false);
  const onSelectionCopiedRef = useRef(options.onSelectionCopied);
  const [restartNonce, setRestartNonce] = useState(0);
  const [status, setStatus] = useState<TerminalStatus>({
    kind: "connecting",
    message: TERMINAL_CONNECTING_MESSAGE,
  });
  useEffect(() => {
    onSelectionCopiedRef.current = options.onSelectionCopied;
  }, [options.onSelectionCopied]);

  const terminalId = useMemo(() => {
    return createTerminalSessionId(
      {
        workspacePath: params.workspacePath,
        conversationId: params.conversationId,
      },
      params.terminalKey,
    );
  }, [params.conversationId, params.terminalKey, params.workspacePath]);

  useEffect(() => {
    const handleRestart = (event: Event) => {
      const customEvent = event as CustomEvent<{ terminalId?: string }>;
      if (customEvent.detail?.terminalId !== terminalId) {
        return;
      }

      openedRef.current = false;
      setStatus({
        kind: "connecting",
        message: TERMINAL_CONNECTING_MESSAGE,
      });
      setRestartNonce((current) => current + 1);
    };

    window.addEventListener(TERMINAL_RESTART_EVENT_NAME, handleRestart);
    return () => {
      window.removeEventListener(TERMINAL_RESTART_EVENT_NAME, handleRestart);
    };
  }, [terminalId]);

  useEffect(() => {
    const container = containerRef.current;
    if (container == null) {
      return;
    }

    let disposed = false;
    let terminal: WTerm | null = null;
    let cleanupListeners: Array<() => void> = [];
    let delayedResizeObserverId: number | null = null;
    let resizeObserver: ResizeObserver | null = null;
    let resizeFrameId: number | null = null;
    let syncedBackendSize: TerminalGridSize | null = null;
    let selectionDragStart: { x: number; y: number } | null = null;
    let selectionDragMoved = false;

    const selectionBelongsToContainer = (selection: Selection) => {
      const nodeBelongsToContainer = (node: Node | null) => {
        if (node == null) {
          return false;
        }

        return container.contains(
          node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement,
        );
      };

      if (
        nodeBelongsToContainer(selection.anchorNode) ||
        nodeBelongsToContainer(selection.focusNode)
      ) {
        return true;
      }

      for (let index = 0; index < selection.rangeCount; index += 1) {
        const range = selection.getRangeAt(index);
        if (nodeBelongsToContainer(range.commonAncestorContainer)) {
          return true;
        }
      }

      return false;
    };

    const copyTerminalSelection = async () => {
      const selection = window.getSelection();
      if (
        selection == null ||
        selection.isCollapsed ||
        !selectionBelongsToContainer(selection)
      ) {
        return;
      }

      const selectedText = selection.toString();
      if (selectedText.length === 0) {
        return;
      }

      if (navigator.clipboard == null) {
        return;
      }

      try {
        await navigator.clipboard.writeText(selectedText);
        onSelectionCopiedRef.current?.();
      } catch {
        // Clipboard writes require browser permission/activation. Ignore failures
        // so terminal input and native selection behavior are unaffected.
      }
    };

    const handleSelectionMouseDown = (event: MouseEvent) => {
      if (event.button !== 0) {
        return;
      }

      selectionDragStart = {
        x: event.clientX,
        y: event.clientY,
      };
      selectionDragMoved = false;
    };

    const handleSelectionMouseMove = (event: MouseEvent) => {
      if (selectionDragStart == null) {
        return;
      }

      if (
        Math.abs(event.clientX - selectionDragStart.x) >= 3 ||
        Math.abs(event.clientY - selectionDragStart.y) >= 3
      ) {
        selectionDragMoved = true;
      }
    };

    const handleSelectionMouseUp = () => {
      if (selectionDragStart == null) {
        return;
      }

      const wasSelectionDrag = selectionDragMoved;
      selectionDragStart = null;
      selectionDragMoved = false;

      if (!wasSelectionDrag) {
        return;
      }

      void copyTerminalSelection();
    };

    container.addEventListener("mousedown", handleSelectionMouseDown);
    window.addEventListener("mousemove", handleSelectionMouseMove);
    window.addEventListener("mouseup", handleSelectionMouseUp);

    const syncTerminalSize = async (
      nextSize: TerminalGridSize,
      options?: { syncBackend?: boolean },
    ) => {
      if (terminal == null) {
        return;
      }

      const currentSize = normalizeTerminalSize(terminal.cols, terminal.rows);
      if (
        currentSize.cols !== nextSize.cols ||
        currentSize.rows !== nextSize.rows
      ) {
        terminal.resize(nextSize.cols, nextSize.rows);
      }

      if (!options?.syncBackend || !openedRef.current) {
        return;
      }

      if (
        syncedBackendSize != null &&
        syncedBackendSize.cols === nextSize.cols &&
        syncedBackendSize.rows === nextSize.rows
      ) {
        return;
      }

      syncedBackendSize = nextSize;

      try {
        await desktopClient.resizeTerminal({
          terminalId,
          cols: nextSize.cols,
          rows: nextSize.rows,
        });
      } catch {
        // Ignore best-effort resize failures during mount or teardown races.
      }
    };

    const scheduleObservedResize = () => {
      if (resizeFrameId != null) {
        return;
      }

      resizeFrameId = window.requestAnimationFrame(() => {
        resizeFrameId = null;

        if (disposed || terminal == null) {
          return;
        }

        const nextSize = measureTerminalGridSize(terminal);
        if (nextSize == null) {
          return;
        }

        void syncTerminalSize(nextSize, { syncBackend: true });
      });
    };

    const setup = async () => {
      terminal = new WTerm(container, {
        cols: DEFAULT_TERMINAL_COLS,
        rows: DEFAULT_TERMINAL_ROWS,
        autoResize: false,
        cursorBlink: true,
        onData(data) {
          if (!openedRef.current) {
            return;
          }

          void desktopClient.writeTerminal({
            terminalId,
            data,
          });
        },
      });
      terminalRef.current = terminal;
      await terminal.init();

      cleanupListeners = await Promise.all([
        desktopClient.listenTerminalOutput(terminalId, (event) => {
          terminal?.write(event.data);
        }),
        desktopClient.listenTerminalExit(terminalId, (event) => {
          const suffix =
            event.signal != null
              ? `terminated by ${event.signal}`
              : `exited with code ${event.exitCode ?? 0}`;
          setStatus({
            kind: "exited",
            message: `Shell ${suffix}. Close and reopen the pane to start a new session.`,
          });
        }),
        desktopClient.listenTerminalErrors(terminalId, (event) => {
          setStatus({
            kind: "error",
            message: event.message,
          });
        }),
      ]);

      if (disposed) {
        cleanupListeners.forEach((cleanup) => {
          cleanup();
        });
        cleanupListeners = [];
        return;
      }

      const initialSize = await waitForStableTerminalSize(terminal);
      await syncTerminalSize(initialSize);

      const session = await desktopClient.openTerminal({
        terminalId,
        workspacePath: params.workspacePath,
        cols: initialSize.cols,
        rows: initialSize.rows,
      });

      if (disposed) {
        cleanupListeners.forEach((cleanup) => {
          cleanup();
        });
        cleanupListeners = [];
        void desktopClient.closeTerminal({ terminalId });
        return;
      }

      openedRef.current = true;
      setStatus(null);

      const resolvedSize = normalizeTerminalSize(session.cols, session.rows);
      syncedBackendSize = resolvedSize;
      await syncTerminalSize(resolvedSize);

      delayedResizeObserverId = window.setTimeout(() => {
        if (disposed) {
          return;
        }

        resizeObserver = new ResizeObserver(() => {
          scheduleObservedResize();
        });
        resizeObserver.observe(container);
      }, INITIAL_RESIZE_OBSERVER_DELAY_MS);

      terminal.focus();
    };

    void setup().catch((error: unknown) => {
      if (disposed) {
        return;
      }

      const message =
        error instanceof Error
          ? error.message
          : "Failed to start terminal session";
      setStatus({
        kind: "error",
        message,
      });
    });

    return () => {
      disposed = true;
      openedRef.current = false;

      container.removeEventListener("mousedown", handleSelectionMouseDown);
      window.removeEventListener("mousemove", handleSelectionMouseMove);
      window.removeEventListener("mouseup", handleSelectionMouseUp);

      if (delayedResizeObserverId != null) {
        window.clearTimeout(delayedResizeObserverId);
      }
      if (resizeFrameId != null) {
        window.cancelAnimationFrame(resizeFrameId);
      }
      resizeObserver?.disconnect();

      for (const cleanup of cleanupListeners) {
        cleanup();
      }

      void desktopClient.closeTerminal({ terminalId });
      terminal?.destroy();
      terminalRef.current = null;
    };
  }, [containerRef, params.workspacePath, restartNonce, terminalId]);

  return { status };
}
