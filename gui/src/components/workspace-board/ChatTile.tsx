import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  PlusIcon,
  RotateCcwIcon,
  SquareTerminalIcon,
  XIcon,
} from "lucide-react";
import {
  DockviewReact,
  positionToDirection,
  type DockviewApi,
  type DockviewGroupPanel,
  type IDockviewHeaderActionsProps,
  type DockviewReadyEvent,
  type IDockviewPanel,
  type IDockviewPanelHeaderProps,
  type IDockviewPanelProps,
} from "dockview-react";

import { ConversationPanel } from "@/components/ConversationPanel";
import { ConversationDockviewHeaderActions } from "@/components/conversation-panel/ConversationDockviewHeaderActions";
import { ConversationDockviewTab } from "@/components/conversation-panel/ConversationDockviewTab";
import { Button } from "@/components/ui/Button";
import { ButtonGroup } from "@/components/ui/ButtonGroup";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/Dialog";
import * as desktopClient from "@/services/desktop/client";

import { AuxiliaryPaneShell } from "./AuxiliaryPaneShell";
import { ChangesPane } from "./ChangesPane";
import { PlaceholderPane } from "./PlaceholderPane";
import { TerminalPane } from "./TerminalPane";
import {
  CHANGES_PANE_ID,
  CHAT_PANE_ID,
  createTerminalSessionId,
  dispatchPaneCloseRequest,
  dispatchTerminalRestartRequest,
  INNER_CHAT_COMPONENT,
  INNER_PLACEHOLDER_COMPONENT,
  isTerminalPanelId,
  PANE_CLOSE_REQUEST_EVENT_NAME,
  PREVIEW_PANE_ID,
  TERMINAL_PANE_ID,
} from "./layout";
import {
  addTerminalTab,
  applyChatTileLayoutConstraints,
  autoCloseUndersizedSidePanes,
  buildDefaultChatTileLayout,
  getTerminalPanels,
  isSingleChatSelfDrop,
  openChatTilePane,
  shouldPreventChatOverlay,
} from "./chatTileLayout";
import { useDockviewLayoutPersistence } from "./hooks/useDockviewLayoutPersistence";
import { useDockviewTheme } from "./hooks/useDockviewTheme";
import type {
  PlaceholderPaneParams,
  TerminalPaneParams,
} from "./types/layout";
import type { ChatTileProps } from "./types/workspaceBoard";
import {
  animatePaneClose,
  animatePaneOpen,
  type PaneResizeTween,
  type ResizeAxis,
} from "./paneResizeAnimation";
import { applySavedConversationLayout } from "./utils/savedLayout";
import "./chat-tile-dockview.css";

function AuxiliaryPaneTab({
  api,
  params,
}: IDockviewPanelHeaderProps<PlaceholderPaneParams>) {
  const isTerminal = params.kind === "terminal";

  return (
    <div className="terminal-pane-tab group/tab inline-flex h-6 min-w-0 items-center gap-1.5 px-1.5 text-xs font-medium tracking-tight text-foreground">
      {isTerminal ? (
        <SquareTerminalIcon className="size-3.5 shrink-0 text-muted-foreground" />
      ) : null}
      <span className="truncate">{params.label}</span>
      {isTerminal ? (
        <button
          type="button"
          aria-label={`Close ${params.label}`}
          className="ml-0.5 inline-flex size-4 shrink-0 items-center justify-center rounded text-muted-foreground opacity-0 transition-all hover:bg-muted hover:text-foreground focus-visible:opacity-100 group-hover/tab:opacity-100"
          onPointerDown={(event) => {
            // Stop dockview from treating the close click as a tab drag/activate.
            event.stopPropagation();
          }}
          onClick={(event) => {
            event.stopPropagation();
            dispatchPaneCloseRequest(`${params.conversationId}:${api.id}`);
          }}
        >
          <XIcon className="size-3" />
        </button>
      ) : null}
    </div>
  );
}

const headerActionsClassName =
  "relative z-20 ml-auto flex h-6 shrink-0 items-center gap-1.5 pointer-events-auto";

export function ChatTile({
  binding,
  canCloseChat,
  onCloseChat,
}: ChatTileProps) {
  const [layoutResetNonce, setLayoutResetNonce] = useState(0);
  const [openPanes, setOpenPanes] = useState({
    changes: false,
    terminal: false,
  });
  // Tracks how many terminal tabs would be destroyed by the toggle-close so the
  // confirmation dialog can warn the user. Closing a single terminal is normal
  // toggle behavior; closing 2+ at once (each with its own PTY) is destructive.
  const [closeTerminalsCount, setCloseTerminalsCount] = useState(0);
  // Drives the open/close size glide. When an auxiliary pane opens or closes we
  // tween its dockview group's grid size (real layout, through dockview's public
  // API) so the chat — the flexible sibling — reflows to its new size *together*
  // with the pane instead of snapping in one frame. Held in a ref so a rapid
  // re-toggle can cancel the in-flight tween. See ./paneResizeAnimation.
  const shellRef = useRef<HTMLElement | null>(null);
  const paneTweenRef = useRef<PaneResizeTween | null>(null);
  const innerApiRef = useRef<DockviewApi | null>(null);
  const innerDisposablesRef = useRef<Array<{ dispose(): void }>>([]);
  const fallbackToDefaultLayoutRef = useRef(false);
  const draggedPanelRef = useRef<IDockviewPanel | null>(null);
  const draggedGroupRef = useRef<DockviewGroupPanel | null>(null);
  const theme = useDockviewTheme();
  const persistConversationLayout = useCallback(
    async (layoutJson: string) => {
      await desktopClient.saveConversationLayout({
        conversationId: binding.conversationId,
        layoutJson,
      });
    },
    [binding.conversationId],
  );
  const {
    isApplyingLayoutRef,
    markPersistedLayout,
    schedulePersist,
  } = useDockviewLayoutPersistence({
    delayMs: 1200,
    onPersist: persistConversationLayout,
  });

  // Guards `autoCloseUndersizedSidePanes` during programmatic layout mutations
  // (opening a pane, adding a terminal tab). `onDidLayoutChange` fires
  // synchronously for `addPanel`, so without this guard a side pane opened on a
  // narrow chat tile is measured below the min width and closed in the same tick
  // it was added — the feature appears broken. Cleared on the next frame so the
  // synchronous layout event batch is suppressed, then user-driven resizes take
  // over again.
  const isProgrammaticMutationRef = useRef(false);
  const clearProgrammaticMutationRafRef = useRef<number | null>(null);
  const withProgrammaticMutation = useCallback(<T,>(fn: () => T): T => {
    isProgrammaticMutationRef.current = true;
    if (clearProgrammaticMutationRafRef.current != null) {
      window.cancelAnimationFrame(clearProgrammaticMutationRafRef.current);
    }
    const result = fn();
    clearProgrammaticMutationRafRef.current = window.requestAnimationFrame(() => {
      isProgrammaticMutationRef.current = false;
      clearProgrammaticMutationRafRef.current = null;
    });
    return result;
  }, []);

  useEffect(() => {
    return () => {
      innerDisposablesRef.current.forEach((disposable) => disposable.dispose());
      innerDisposablesRef.current = [];
      draggedPanelRef.current = null;
      draggedGroupRef.current = null;
      if (clearProgrammaticMutationRafRef.current != null) {
        window.cancelAnimationFrame(clearProgrammaticMutationRafRef.current);
        clearProgrammaticMutationRafRef.current = null;
      }
      paneTweenRef.current?.cancel();
      paneTweenRef.current = null;
    };
  }, []);

  const scheduleInnerLayoutSave = useCallback(() => {
    schedulePersist(() => innerApiRef.current);
  }, [schedulePersist]);

  // Open a pane and glide chat + the new pane to their final sizes together.
  // dockview adds the pane and settles its target size synchronously, so we read
  // that target back, shrink the pane to a sliver, then tween it (and thus chat,
  // the flexible sibling) up to target. The programmatic-mutation guard is held
  // for the whole tween so `autoCloseUndersizedSidePanes` doesn't close the pane
  // while it grows up through the min-width threshold.
  const runOpenPaneAnimation = useCallback(
    (api: DockviewApi, kind: "preview" | "terminal" | "changes") => {
      // A terminal that already exists just gets focused (no new group); only the
      // first terminal opens a fresh "below" group worth animating.
      const paneId =
        kind === "changes"
          ? CHANGES_PANE_ID
          : kind === "preview"
            ? PREVIEW_PANE_ID
            : TERMINAL_PANE_ID;
      const wasOpen =
        kind === "terminal"
          ? getTerminalPanels(api).length > 0
          : api.getPanel(paneId) != null;

      paneTweenRef.current?.cancel();
      isProgrammaticMutationRef.current = true;
      openChatTilePane(api, binding, kind);

      const group = api.getPanel(paneId)?.group ?? null;
      if (wasOpen || group == null) {
        // Nothing newly opened to animate — release the guard on the next frame
        // (matches withProgrammaticMutation) so the synchronous layout batch is
        // still suppressed.
        window.requestAnimationFrame(() => {
          isProgrammaticMutationRef.current = false;
        });
        return;
      }

      // Preview/Changes open to chat's right (animate width); the first terminal
      // opens below (animate height).
      const axis: ResizeAxis = kind === "terminal" ? "height" : "width";
      paneTweenRef.current = animatePaneOpen(group, axis, () => {
        paneTweenRef.current = null;
        // Defer to the next frame: under reduced motion animatePaneOpen calls
        // this synchronously (no tween), and releasing the guard in the same tick
        // as the addPanel above would let its synchronous onDidLayoutChange run
        // autoCloseUndersizedSidePanes and close the pane just opened.
        window.requestAnimationFrame(() => {
          isProgrammaticMutationRef.current = false;
        });
      });
    },
    [binding],
  );

  // Any pane close (toolbar button or a terminal tab's ×) goes through the close
  // request event. When the close removes the pane's whole group (chat will
  // reflow to reclaim the space) glide that group down to a sliver so chat
  // expands smoothly instead of snapping back. The pane's own fade-out
  // (AuxiliaryPaneShell) runs over the same window and performs the real close;
  // this only animates the surrounding reflow.
  useEffect(() => {
    function handleCloseRequest(event: Event) {
      const paneId = (event as CustomEvent<{ paneId?: string }>).detail?.paneId;
      const prefix = `${binding.conversationId}:`;
      if (paneId == null || !paneId.startsWith(prefix)) {
        return;
      }
      const api = innerApiRef.current;
      if (api == null) {
        return;
      }
      const dockviewPanelId = paneId.slice(prefix.length);
      const panel = api.getPanel(dockviewPanelId);
      // Only glide when closing the pane collapses its group (a lone changes /
      // preview / last-terminal pane). Closing one terminal tab among several
      // leaves the group — and chat's size — unchanged, so there's nothing to
      // animate.
      if (panel == null || panel.group.panels.length > 1) {
        return;
      }
      const axis: ResizeAxis = isTerminalPanelId(dockviewPanelId)
        ? "height"
        : "width";
      paneTweenRef.current?.cancel();
      paneTweenRef.current = animatePaneClose(api, dockviewPanelId, axis);
    }

    window.addEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
    return () => {
      window.removeEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
    };
  }, [binding.conversationId]);

  const handleOpenPane = useCallback(
    (kind: "preview" | "terminal" | "changes") => {
      const api = innerApiRef.current;
      if (api == null) {
        return;
      }

      runOpenPaneAnimation(api, kind);
      scheduleInnerLayoutSave();
    },
    [binding, runOpenPaneAnimation, scheduleInnerLayoutSave],
  );

  // Track which auxiliary panes are open so the header toggles can show an active
  // indicator. Only flips the state object when it actually changes so the memoized
  // header-actions component (and thus the dockview group control) stays stable.
  const recomputeOpenPanes = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      return;
    }

    const changes = api.getPanel(CHANGES_PANE_ID) != null;
    const terminal = getTerminalPanels(api).length > 0;
    setOpenPanes((current) =>
      current.changes === changes && current.terminal === terminal
        ? current
        : { changes, terminal },
    );
  }, []);

  const handleToggleChanges = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      return;
    }

    if (api.getPanel(CHANGES_PANE_ID) != null) {
      dispatchPaneCloseRequest(`${binding.conversationId}:${CHANGES_PANE_ID}`);
      return;
    }

    runOpenPaneAnimation(api, "changes");
    scheduleInnerLayoutSave();
  }, [binding, runOpenPaneAnimation, scheduleInnerLayoutSave]);

  const handleToggleTerminal = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      return;
    }

    const terminals = getTerminalPanels(api);
    if (terminals.length > 0) {
      // A single terminal closes immediately (normal toggle). Two or more tabs
      // each hold a live PTY, so confirm before tearing them all down at once.
      if (terminals.length > 1) {
        setCloseTerminalsCount(terminals.length);
        return;
      }
      dispatchPaneCloseRequest(`${binding.conversationId}:${terminals[0].id}`);
      return;
    }

    runOpenPaneAnimation(api, "terminal");
    scheduleInnerLayoutSave();
  }, [binding, runOpenPaneAnimation, scheduleInnerLayoutSave]);

  const handleCloseAllTerminalsConfirm = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      setCloseTerminalsCount(0);
      return;
    }
    for (const panel of getTerminalPanels(api)) {
      dispatchPaneCloseRequest(`${binding.conversationId}:${panel.id}`);
    }
    setCloseTerminalsCount(0);
  }, [binding.conversationId]);

  const handleAddTerminal = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      return;
    }

    withProgrammaticMutation(() => addTerminalTab(api, binding));
    scheduleInnerLayoutSave();
  }, [binding, scheduleInnerLayoutSave, withProgrammaticMutation]);

  const headerActionsComponent = useCallback(function InnerHeaderActions({
    activePanel,
  }: IDockviewHeaderActionsProps) {
    if (activePanel?.id === CHAT_PANE_ID) {
      return (
        <ConversationDockviewHeaderActions
          binding={binding}
          canCloseChat={canCloseChat}
          onCloseChat={onCloseChat}
          onOpenPreview={() => {
            handleOpenPane("preview");
          }}
          onOpenTerminal={handleToggleTerminal}
          onOpenChanges={handleToggleChanges}
          isChangesOpen={openPanes.changes}
          isTerminalOpen={openPanes.terminal}
        />
      );
    }

    const panelParams = activePanel?.params as Partial<PlaceholderPaneParams> | undefined;
    const kind = panelParams?.kind;

    if (
      activePanel == null ||
      (kind !== "preview" && kind !== "terminal" && kind !== "changes")
    ) {
      return null;
    }

    const handleClose = () => {
      dispatchPaneCloseRequest(`${binding.conversationId}:${activePanel.id}`);
    };

    if (kind === "preview" || kind === "changes") {
      return (
        <div className={headerActionsClassName}>
          <Button
            variant="outline"
            size="icon-sm"
            aria-label={kind === "changes" ? "Close changes" : "Close preview"}
            onClick={handleClose}
          >
            <XIcon />
          </Button>
        </div>
      );
    }

    const resolvedParams = panelParams ?? {};
    const workspacePath = typeof resolvedParams.workspacePath === "string"
      ? resolvedParams.workspacePath
      : "";
    const conversationId = typeof resolvedParams.conversationId === "string"
      ? resolvedParams.conversationId
      : "";
    const terminalId = createTerminalSessionId(
      {
        workspacePath,
        conversationId,
      },
      resolvedParams.terminalKey,
    );

    return (
      <div className={headerActionsClassName}>
        <Button
          variant="outline"
          size="icon-sm"
          aria-label="New terminal"
          onClick={handleAddTerminal}
        >
          <PlusIcon />
        </Button>
        <ButtonGroup aria-label="Terminal actions">
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Restart terminal"
            onClick={() => {
              dispatchTerminalRestartRequest(terminalId);
            }}
          >
            <RotateCcwIcon />
          </Button>
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Close terminal"
            onClick={handleClose}
          >
            <XIcon />
          </Button>
        </ButtonGroup>
      </div>
    );
  }, [
    binding,
    canCloseChat,
    handleAddTerminal,
    handleOpenPane,
    handleToggleChanges,
    handleToggleTerminal,
    onCloseChat,
    openPanes.changes,
    openPanes.terminal,
  ]);

  const components = useMemo(
    () => ({
      [INNER_CHAT_COMPONENT]: function ConversationPane() {
        return (
          <ConversationPanel
            binding={binding}
            canCloseChat={canCloseChat}
            onCloseChat={onCloseChat}
            onOpenPreview={() => {
              handleOpenPane("preview");
            }}
            onOpenTerminal={() => {
              handleOpenPane("terminal");
            }}
            showHeader={false}
            windowDragEnabled={false}
          />
        );
      },
      [INNER_PLACEHOLDER_COMPONENT]: function AuxiliaryPane(
        props: IDockviewPanelProps<PlaceholderPaneParams>,
      ) {
        const kind = props.params.kind;
        const content =
          kind === "terminal" ? (
            <TerminalPane
              {...(props as IDockviewPanelProps<TerminalPaneParams>)}
            />
          ) : kind === "changes" ? (
            <ChangesPane {...props} />
          ) : (
            <PlaceholderPane {...props} />
          );

        return (
          <AuxiliaryPaneShell
            api={props.api}
            paneId={`${props.params.conversationId}:${props.api.id}`}
          >
            {content}
          </AuxiliaryPaneShell>
        );
      },
    }),
    [binding, canCloseChat, handleOpenPane, onCloseChat],
  );

  const tabComponents = useMemo(
    () => ({
      [INNER_CHAT_COMPONENT]: function ChatPaneTab() {
        return <ConversationDockviewTab binding={binding} />;
      },
      [INNER_PLACEHOLDER_COMPONENT]: AuxiliaryPaneTab,
    }),
    [binding],
  );

  const buildDefaultInnerLayout = useCallback(
    (api: DockviewApi) => {
      buildDefaultChatTileLayout(api, binding);
    },
    [binding],
  );
  const finishInnerLayoutRestore = useCallback(
    (layoutJson: string | null) => {
      markPersistedLayout(layoutJson);
      // Defer clearing the restore guard past the current frame: dockview emits
      // additional onDidLayoutChange events as the restored layout settles (and
      // from applyChatTileLayoutConstraints below), which would otherwise run
      // autoCloseUndersizedSidePanes and close a restored narrow side pane.
      window.requestAnimationFrame(() => {
        isApplyingLayoutRef.current = false;
      });
    },
    [isApplyingLayoutRef, markPersistedLayout],
  );

  const restoreInnerLayout = useCallback(
    async (api: DockviewApi) => {
      isApplyingLayoutRef.current = true;
      if (fallbackToDefaultLayoutRef.current) {
        fallbackToDefaultLayoutRef.current = false;
        finishInnerLayoutRestore(null);
        buildDefaultInnerLayout(api);
        return;
      }

      const savedLayoutJson = await desktopClient.getConversationLayout(
        binding.conversationId,
      );
      const restoreResult = applySavedConversationLayout(api, savedLayoutJson);
      if (restoreResult.kind === "restored") {
        applyChatTileLayoutConstraints(api);
        finishInnerLayoutRestore(savedLayoutJson);
        return;
      }

      if (restoreResult.kind === "fallback") {
        fallbackToDefaultLayoutRef.current = true;
        isApplyingLayoutRef.current = false;
        setLayoutResetNonce((current) => current + 1);
        return;
      }

      finishInnerLayoutRestore(null);
      buildDefaultInnerLayout(api);
    },
    [
      binding.conversationId,
      buildDefaultInnerLayout,
      finishInnerLayoutRestore,
      isApplyingLayoutRef,
    ],
  );

  const handleInnerReady = useCallback(
    (event: DockviewReadyEvent) => {
      innerDisposablesRef.current.forEach((disposable) => disposable.dispose());
      innerDisposablesRef.current = [];
      innerApiRef.current = event.api;

      innerDisposablesRef.current = [
        event.api.onDidLayoutChange(() => {
          draggedPanelRef.current = null;
          draggedGroupRef.current = null;
          applyChatTileLayoutConstraints(event.api);
          // Skip while a saved layout is being applied so restoring a narrow pane
          // doesn't immediately close it, and while a programmatic open/add is
          // settling (onDidLayoutChange fires synchronously for addPanel, which
          // would otherwise close the pane just opened on a narrow tile); only
          // react to user-driven resizes.
          if (!isApplyingLayoutRef.current && !isProgrammaticMutationRef.current) {
            autoCloseUndersizedSidePanes(event.api);
          }
          recomputeOpenPanes();
          scheduleInnerLayoutSave();
        }),
        event.api.onWillDragPanel((dragEvent) => {
          draggedPanelRef.current = dragEvent.panel;
          draggedGroupRef.current = null;
        }),
        event.api.onWillDragGroup((dragEvent) => {
          draggedGroupRef.current = dragEvent.group;
          draggedPanelRef.current = null;
        }),
        event.api.onWillShowOverlay((overlayEvent) => {
          if (
            shouldPreventChatOverlay(
              draggedPanelRef.current,
              draggedGroupRef.current,
              overlayEvent.group,
              overlayEvent.position,
            )
          ) {
            overlayEvent.preventDefault();
          }
        }),
        event.api.onWillDrop((dropEvent) => {
          const draggedPanel = draggedPanelRef.current;
          const draggedGroup = draggedGroupRef.current;
          if (isSingleChatSelfDrop(draggedPanel, draggedGroup, dropEvent.group)) {
            dropEvent.preventDefault();
            draggedPanelRef.current = null;
            draggedGroupRef.current = null;
            return;
          }

          if (
            shouldPreventChatOverlay(
              draggedPanel,
              draggedGroup,
              dropEvent.group,
              dropEvent.position,
            )
          ) {
            dropEvent.preventDefault();
            return;
          }

          if (draggedPanel != null) {
            dropEvent.preventDefault();

            if (dropEvent.group != null) {
              draggedPanel.api.moveTo({
                group: dropEvent.group,
                position: dropEvent.position,
              });
            } else {
              const newGroup = event.api.addGroup({
                direction: positionToDirection(dropEvent.position),
              });
              draggedPanel.api.moveTo({
                group: newGroup,
              });
            }

            draggedPanelRef.current = null;
            draggedGroupRef.current = null;
            return;
          }

          const sourceGroup = draggedGroup;
          if (sourceGroup == null) {
            return;
          }

          dropEvent.preventDefault();

          if (dropEvent.group != null) {
            sourceGroup.api.moveTo({
              group: dropEvent.group,
              position: dropEvent.position,
            });
          } else {
            sourceGroup.api.moveTo({
              position: dropEvent.position,
            });
          }

          draggedPanelRef.current = null;
          draggedGroupRef.current = null;
        }),
      ];

      void restoreInnerLayout(event.api);
    },
    [
      isApplyingLayoutRef,
      recomputeOpenPanes,
      restoreInnerLayout,
      scheduleInnerLayoutSave,
    ],
  );

  return (
    <section
      ref={shellRef}
      className="chat-tile-shell relative flex h-full min-h-0 min-w-0"
    >
      <DockviewReact
        key={`${binding.conversationId}:${layoutResetNonce}`}
        className="chat-tile-inner-dock h-full w-full"
        components={components}
        defaultTabComponent={AuxiliaryPaneTab}
        disableFloatingGroups
        onReady={handleInnerReady}
        rightHeaderActionsComponent={headerActionsComponent}
        singleTabMode="fullwidth"
        tabComponents={tabComponents}
        theme={theme}
      />
      <Dialog
        open={closeTerminalsCount > 0}
        onOpenChange={(open) => {
          if (!open) {
            setCloseTerminalsCount(0);
          }
        }}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Close {closeTerminalsCount} terminals?</DialogTitle>
            <DialogDescription>
              This closes every terminal tab and ends its shell session. This
              can't be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setCloseTerminalsCount(0)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              variant="destructive"
              onClick={handleCloseAllTerminalsConfirm}
            >
              Close terminals
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}
