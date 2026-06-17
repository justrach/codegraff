import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  RotateCcwIcon,
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

import { ChangesPane } from "./ChangesPane";
import { PlaceholderPane } from "./PlaceholderPane";
import { TerminalPane } from "./TerminalPane";
import {
  CHAT_PANE_ID,
  createTerminalSessionId,
  dispatchTerminalRestartRequest,
  INNER_CHAT_COMPONENT,
  INNER_PLACEHOLDER_COMPONENT,
} from "./layout";
import {
  applyChatTileLayoutConstraints,
  buildDefaultChatTileLayout,
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
  params,
}: IDockviewPanelHeaderProps<PlaceholderPaneParams>) {
  return (
    <div className="terminal-pane-tab inline-flex h-6 min-w-0 items-center gap-1.5 px-1.5 text-xs font-medium tracking-tight text-foreground">
      <span className="truncate">{params.label}</span>
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

  useEffect(() => {
    return () => {
      innerDisposablesRef.current.forEach((disposable) => disposable.dispose());
      innerDisposablesRef.current = [];
      draggedPanelRef.current = null;
      draggedGroupRef.current = null;
    };
  }, []);

  const scheduleInnerLayoutSave = useCallback(() => {
    schedulePersist(() => innerApiRef.current);
  }, [schedulePersist]);

  const handleOpenPane = useCallback(
    (kind: "preview" | "terminal" | "changes") => {
      const api = innerApiRef.current;
      if (api == null) {
        return;
      }

      openChatTilePane(api, binding, kind);
      scheduleInnerLayoutSave();
    },
    [binding, scheduleInnerLayoutSave],
  );

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
          onOpenTerminal={() => {
            handleOpenPane("terminal");
          }}
          onOpenChanges={() => {
            handleOpenPane("changes");
          }}
        />
      );
    }

    const panelParams = activePanel?.params as Partial<PlaceholderPaneParams> | undefined;
    const kind = panelParams?.kind;

    if (activePanel == null || (kind !== "preview" && kind !== "terminal")) {
      return null;
    }

    const handleClose = () => {
      activePanel.api.close();
    };

    if (kind === "preview") {
      return (
        <div className={headerActionsClassName}>
          <Button
            variant="outline"
            size="icon-sm"
            aria-label="Close preview"
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
    const terminalId = createTerminalSessionId({
      workspacePath,
      conversationId,
    });

    return (
      <div className={headerActionsClassName}>
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
  }, [binding, canCloseChat, handleOpenPane, onCloseChat]);

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
        if (props.params.kind === "terminal") {
          return (
            <TerminalPane
              {...(props as IDockviewPanelProps<TerminalPaneParams>)}
            />
          );
        }

        if (props.params.kind === "changes") {
          return <ChangesPane {...props} />;
        }

        return <PlaceholderPane {...props} />;
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
      isApplyingLayoutRef.current = false;
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
        finishInnerLayoutRestore(savedLayoutJson);
        applyChatTileLayoutConstraints(api);
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
    [restoreInnerLayout, scheduleInnerLayoutSave],
  );

  return (
    <section className="chat-tile-shell relative flex h-full min-h-0 min-w-0">
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
