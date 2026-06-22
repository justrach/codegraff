import { useEffect, useMemo, useRef, useState, type RefObject } from "react";
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

export function useTerminalSession(
  params: TerminalPaneParams,
  containerRef: RefObject<HTMLDivElement | null>,
) {
  const terminalRef = useRef<WTerm | null>(null);
  const openedRef = useRef(false);
  const [restartNonce, setRestartNonce] = useState(0);
  const [status, setStatus] = useState<TerminalStatus>({
    kind: "connecting",
    message: TERMINAL_CONNECTING_MESSAGE,
  });
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
    let didOpenSession = false;
    let activeTerminalInstanceId: string | null = null;
    let activeScrollbackSeq = 0;
    const pendingOutputEvents: Array<Parameters<Parameters<typeof desktopClient.listenTerminalOutput>[1]>[0]> = [];
    const pendingExitEvents: Array<Parameters<Parameters<typeof desktopClient.listenTerminalExit>[1]>[0]> = [];
    const pendingErrorEvents: Array<Parameters<Parameters<typeof desktopClient.listenTerminalErrors>[1]>[0]> = [];

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
          terminalInstanceId: activeTerminalInstanceId,
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
            terminalInstanceId: activeTerminalInstanceId,
            data,
          });
        },
      });
      terminalRef.current = terminal;
      await terminal.init();

      cleanupListeners = await Promise.all([
        desktopClient.listenTerminalOutput(terminalId, (event) => {
          if (activeTerminalInstanceId == null) {
            pendingOutputEvents.push(event);
            return;
          }
          if (event.terminalInstanceId !== activeTerminalInstanceId) return;
          if ((event.terminalOutputSeq ?? 0) <= activeScrollbackSeq) return;
          activeScrollbackSeq = event.terminalOutputSeq ?? activeScrollbackSeq;
          terminal?.write(event.data);
        }),
        desktopClient.listenTerminalExit(terminalId, (event) => {
          if (activeTerminalInstanceId == null) {
            pendingExitEvents.push(event);
            return;
          }
          if (event.terminalInstanceId !== activeTerminalInstanceId) return;
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
          if (activeTerminalInstanceId == null) {
            pendingErrorEvents.push(event);
            return;
          }
          if (event.terminalInstanceId !== activeTerminalInstanceId) return;
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
      didOpenSession = true;

      if (disposed) {
        cleanupListeners.forEach((cleanup) => {
          cleanup();
        });
        cleanupListeners = [];
        void desktopClient.closeTerminal({ terminalId, terminalInstanceId: session.terminalInstanceId ?? null });
        return;
      }

      if (session.scrollback != null && session.scrollback.length > 0) {
        terminal.write(session.scrollback);
      }

      activeTerminalInstanceId = session.terminalInstanceId ?? null;
      activeScrollbackSeq = session.scrollbackSeq ?? 0;
      for (const event of pendingOutputEvents.splice(0)) {
        if (
          event.terminalInstanceId === activeTerminalInstanceId &&
          (event.terminalOutputSeq ?? 0) > activeScrollbackSeq
        ) {
          activeScrollbackSeq = event.terminalOutputSeq ?? activeScrollbackSeq;
          terminal.write(event.data);
        }
      }
      for (const event of pendingErrorEvents.splice(0)) {
        if (event.terminalInstanceId === activeTerminalInstanceId) {
          setStatus({ kind: "error", message: event.message });
        }
      }
      for (const event of pendingExitEvents.splice(0)) {
        if (event.terminalInstanceId === activeTerminalInstanceId) {
          const suffix =
            event.signal != null
              ? `terminated by ${event.signal}`
              : `exited with code ${event.exitCode ?? 0}`;
          setStatus({
            kind: "exited",
            message: `Shell ${suffix}. Close and reopen the pane to start a new session.`,
          });
        }
      }

      if (disposed) {
        cleanupListeners.forEach((cleanup) => {
          cleanup();
        });
        cleanupListeners = [];
        void desktopClient.closeTerminal({ terminalId, terminalInstanceId: activeTerminalInstanceId });
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

      if (didOpenSession) {
        void desktopClient.closeTerminal({ terminalId, terminalInstanceId: activeTerminalInstanceId });
      }
      terminal?.destroy();
      terminalRef.current = null;
    };
  }, [containerRef, params.workspacePath, restartNonce, terminalId]);

  return { status };
}
