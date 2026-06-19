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
  PANE_CLOSE_REQUEST_EVENT_NAME,
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
  // Briefly enables a width/position transition on the dock's view containers so
  // chat glides to its new size when a pane opens/closes (see chat-tile-dockview.css).
  // Toggled imperatively (not via state) so the class is in the DOM *before* the
  // synchronous dockview size mutation, otherwise the transition wouldn't fire.
  const shellRef = useRef<HTMLElement | null>(null);
  const layoutAnimateTimeoutRef = useRef<number | null>(null);
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
    };
  }, []);

  const scheduleInnerLayoutSave = useCallback(() => {
    schedulePersist(() => innerApiRef.current);
  }, [schedulePersist]);

  // Turn on the dock's size transition for one open/close cycle so chat (and any
  // other panes) glide to their new size instead of snapping. The window covers
  // an exit fade (~180ms) plus the size transition (~320ms); re-toggling resets it.
  const runLayoutAnimation = useCallback(() => {
    const dock = shellRef.current?.querySelector(".chat-tile-inner-dock");
    if (dock == null) {
      return;
    }
    dock.classList.add("cg-animate-layout");
    if (layoutAnimateTimeoutRef.current != null) {
      window.clearTimeout(layoutAnimateTimeoutRef.current);
    }
    layoutAnimateTimeoutRef.current = window.setTimeout(() => {
      dock.classList.remove("cg-animate-layout");
      layoutAnimateTimeoutRef.current = null;
    }, 600);
  }, []);

  // Any pane close (toolbar button or a terminal tab's ×) goes through the close
  // request event; animate the resulting reflow for this conversation's panes.
  useEffect(() => {
    function handleCloseRequest(event: Event) {
      const paneId = (event as CustomEvent<{ paneId?: string }>).detail?.paneId;
      if (paneId != null && paneId.startsWith(`${binding.conversationId}:`)) {
        runLayoutAnimation();
      }
    }

    window.addEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
    return () => {
      window.removeEventListener(PANE_CLOSE_REQUEST_EVENT_NAME, handleCloseRequest);
      if (layoutAnimateTimeoutRef.current != null) {
        window.clearTimeout(layoutAnimateTimeoutRef.current);
      }
    };
  }, [binding.conversationId, runLayoutAnimation]);

  const handleOpenPane = useCallback(
    (kind: "preview" | "terminal" | "changes") => {
      const api = innerApiRef.current;
      if (api == null) {
        return;
      }

      runLayoutAnimation();
      withProgrammaticMutation(() => openChatTilePane(api, binding, kind));
      scheduleInnerLayoutSave();
    },
    [binding, runLayoutAnimation, scheduleInnerLayoutSave, withProgrammaticMutation],
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

    runLayoutAnimation();
    withProgrammaticMutation(() => openChatTilePane(api, binding, "changes"));
    scheduleInnerLayoutSave();
  }, [binding, runLayoutAnimation, scheduleInnerLayoutSave, withProgrammaticMutation]);

  const handleToggleTerminal = useCallback(() => {
    const api = innerApiRef.current;
    if (api == null) {
      return;
    }

    const terminals = getTerminalPanels(api);
    if (terminals.length > 0) {
      // Re-clicking the toggle closes the whole bottom terminal panel.
      for (const panel of terminals) {
        dispatchPaneCloseRequest(`${binding.conversationId}:${panel.id}`);
      }
      return;
    }

    runLayoutAnimation();
    withProgrammaticMutation(() => openChatTilePane(api, binding, "terminal"));
    scheduleInnerLayoutSave();
  }, [binding, runLayoutAnimation, scheduleInnerLayoutSave, withProgrammaticMutation]);

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
    </section>
  );
}
