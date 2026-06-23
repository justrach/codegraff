import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  DockviewReact,
  type DockviewApi,
  type DockviewReadyEvent,
  type IDockviewPanelProps,
} from "dockview-react";

import { ConversationPanel } from "@/components/ConversationPanel";
import { NewChatScreen } from "@/components/new-chat-screen/NewChatScreen";
import {
  useBoardSelection,
  useBoardSelectionKey,
  useSessionActions,
  useSessionStore,
} from "@/hooks/useSession";
import * as desktopClient from "@/services/desktop/client";
import type { ChatBinding } from "@/services/desktop/types/contracts";
import {
  areChatBindingsEqual,
  ensureConversationViewLoaded,
  sessionStore,
} from "@/app/sessionStore";

import { ChatTile } from "./ChatTile";
import {
  OUTER_CHAT_COMPONENT,
  clearActiveDraggedChatBinding,
  createChatPanelId,
  extractBindingsFromSerializedLayout,
  hasChatBindingDataTransfer,
  readChatBindingFromDataTransfer,
  serializeDockviewLayout,
} from "./layout";
import {
  getActiveOuterBinding,
  getChatTitle,
  getOuterPanelBinding,
} from "./workspaceBoardUtils";
import { useDockviewLayoutPersistence } from "./hooks/useDockviewLayoutPersistence";
import { useDockviewTheme } from "./hooks/useDockviewTheme";
import type { OuterChatPanelParams } from "./types/layout";
import { applySavedWorkspaceLayout } from "./utils/savedLayout";

export function WorkspaceBoard() {
  const selection = useBoardSelection();
  const selectionKey = useBoardSelectionKey();
  const { selectConversation, startNewChat } = useSessionActions();
  const setSelection = useSessionStore((state) => state.setBoardSelection);
  const [layoutResetNonce, setLayoutResetNonce] = useState(0);
  const outerApiRef = useRef<DockviewApi | null>(null);
  const disposablesRef = useRef<Array<{ dispose(): void }>>([]);
  const fallbackBindingsRef = useRef<ChatBinding[] | null>(null);
  const emptySelectionRequestRef = useRef(false);
  const selectionRef = useRef(sessionStore.getState().selection);
  const theme = useDockviewTheme();
  const persistWorkspaceLayout = useCallback(
    async (layoutJson: string) => {
      const currentSelection = selectionRef.current;
      if (currentSelection.kind !== "saved-workspace") {
        return;
      }

      await desktopClient.updateSavedWorkspaceLayout({
        workspaceId: currentSelection.workspace.id,
        layoutJson,
      });
    },
    [],
  );
  const {
    flushPendingPersist,
    isApplyingLayoutRef,
    markPersistedLayout,
    schedulePersist,
  } = useDockviewLayoutPersistence({
    delayMs: 1200,
    onPersist: persistWorkspaceLayout,
  });

  useEffect(() => {
    return () => {
      disposablesRef.current.forEach((disposable) => disposable.dispose());
      disposablesRef.current = [];
    };
  }, []);

  useEffect(() => {
    if (selection.kind !== "empty") {
      emptySelectionRequestRef.current = false;
      return;
    }

    if (emptySelectionRequestRef.current) {
      return;
    }

    emptySelectionRequestRef.current = true;
    void startNewChat();
  }, [selection.kind, startNewChat]);

  const applyOuterLayoutConstraints = useCallback(
    (api: DockviewApi) => {
      api.groups.forEach((group) => {
        group.locked = false;
        group.header.hidden = true;
        group.element.classList.add("workspace-board-outer-group");
      });
    },
    [],
  );

  const addOuterChatPanel = useCallback(
    (
      api: DockviewApi,
      binding: ChatBinding,
      options?: { referencePanel?: string; position?: "left" | "right" },
    ) => {
      const panelId = createChatPanelId(binding);
      const existingPanel = api.getPanel(panelId);
      if (existingPanel != null) {
        existingPanel.focus();
        return existingPanel;
      }

      const title = getChatTitle(binding);
      const panel = api.addPanel<OuterChatPanelParams>({
        id: panelId,
        component: OUTER_CHAT_COMPONENT,
        title,
        params: {
          ...binding,
          title,
        },
        position:
          options?.referencePanel != null
            ? {
                direction: options.position ?? "right",
                referencePanel: options.referencePanel,
              }
            : undefined,
      });
      applyOuterLayoutConstraints(api);
      return panel;
    },
    [applyOuterLayoutConstraints],
  );

  const buildDefaultOuterLayout = useCallback(
    (api: DockviewApi, bindings: ChatBinding[]) => {
      api.clear();
      bindings.forEach((binding, index) => {
        addOuterChatPanel(api, binding, index === 0
          ? undefined
          : {
              referencePanel: createChatPanelId(bindings[index - 1]),
              position: "right",
            });
      });
      applyOuterLayoutConstraints(api);
    },
    [addOuterChatPanel, applyOuterLayoutConstraints],
  );

  const persistSavedWorkspaceLayout = useCallback(() => {
    if (selectionRef.current.kind !== "saved-workspace") {
      return;
    }

    const workspaceId = selectionRef.current.workspace.id;
    schedulePersist(
      () => outerApiRef.current,
      async (layoutJson) => {
        await desktopClient.updateSavedWorkspaceLayout({
          workspaceId,
          layoutJson,
        });
      },
      workspaceId,
    );
  }, [schedulePersist]);
  const finishSelectionRestore = useCallback(
    (layoutJson: string | null) => {
      markPersistedLayout(
        layoutJson,
        selectionRef.current.kind === "saved-workspace"
          ? selectionRef.current.workspace.id
          : undefined,
      );
      isApplyingLayoutRef.current = false;
    },
    [isApplyingLayoutRef, markPersistedLayout],
  );

  const focusChat = useCallback(
    async (binding: ChatBinding) =>
      await selectConversation(binding.workspacePath, binding.conversationId),
    [selectConversation],
  );

  const canCloseChatPanel = useCallback(
    (binding: ChatBinding) => {
      const api = outerApiRef.current;
      if (selectionRef.current.kind !== "saved-workspace" || api == null) {
        return false;
      }

      if (api.totalPanels <= 1) {
        return false;
      }

      return api.getPanel(createChatPanelId(binding)) != null;
    },
    [],
  );

  const closeChatPanel = useCallback(
    (binding: ChatBinding) => {
      const api = outerApiRef.current;
      const currentSelection = selectionRef.current;
      if (currentSelection.kind !== "saved-workspace" || api == null) {
        return;
      }

      if (api.totalPanels <= 1) {
        return;
      }

      const panel = api.getPanel(createChatPanelId(binding));
      if (panel == null) {
        return;
      }

      api.removePanel(panel);

      if (
        areChatBindingsEqual(currentSelection.activeChat, binding)
      ) {
        setSelection({
          kind: "saved-workspace",
          workspace: currentSelection.workspace,
          activeChat: getActiveOuterBinding(api),
        });
      }
    },
    [setSelection],
  );

  const restoreSelection = useCallback(
    async (api: DockviewApi) => {
      flushPendingPersist();
      isApplyingLayoutRef.current = true;
      if (fallbackBindingsRef.current != null) {
        const bindings = fallbackBindingsRef.current;
        fallbackBindingsRef.current = null;
        finishSelectionRestore(null);
        buildDefaultOuterLayout(api, bindings);
        return;
      }

      if (selection.kind === "single-chat") {
        finishSelectionRestore(null);
        buildDefaultOuterLayout(api, [selection.chat]);
        return;
      }

      if (selection.kind !== "saved-workspace") {
        finishSelectionRestore(null);
        api.clear();
        return;
      }

      const restoreResult = applySavedWorkspaceLayout(
        api,
        selection.workspace.layoutJson,
      );
      if (restoreResult.kind === "fallback") {
        fallbackBindingsRef.current = restoreResult.bindings;
        isApplyingLayoutRef.current = false;
        setLayoutResetNonce((current) => current + 1);
        return;
      }

      if (restoreResult.kind === "restored") {
        finishSelectionRestore(selection.workspace.layoutJson);
        applyOuterLayoutConstraints(api);
        const activeBinding = getActiveOuterBinding(api);
        if (
          activeBinding != null &&
          !areChatBindingsEqual(selection.activeChat, activeBinding)
        ) {
          setSelection({
            kind: "saved-workspace",
            workspace: selection.workspace,
            activeChat: activeBinding,
          });
        }
        return;
      }

      finishSelectionRestore(null);
      buildDefaultOuterLayout(api, restoreResult.bindings);
      const activeBinding = getActiveOuterBinding(api);
      if (
        activeBinding != null &&
        !areChatBindingsEqual(selection.activeChat, activeBinding)
      ) {
        setSelection({
          kind: "saved-workspace",
          workspace: selection.workspace,
          activeChat: activeBinding,
        });
      }
    },
    [
      applyOuterLayoutConstraints,
      buildDefaultOuterLayout,
      finishSelectionRestore,
      flushPendingPersist,
      isApplyingLayoutRef,
      selection,
      setSelection,
    ],
  );

  const addChatToBoard = useCallback(
    async (
      binding: ChatBinding,
      options?: { position?: "left" | "right"; referenceBinding?: ChatBinding },
    ) => {
      const ensuredView = await ensureConversationViewLoaded(binding);
      if (ensuredView == null) {
        return;
      }

      if (selection.kind === "empty") {
        setSelection({ kind: "single-chat", chat: binding });
        void focusChat(binding);
        return;
      }

      const api = outerApiRef.current;
      if (api == null) {
        return;
      }

      const existingPanel = api.getPanel(createChatPanelId(binding));
      if (existingPanel != null) {
        existingPanel.focus();
        if (selection.kind === "saved-workspace") {
          setSelection({
            kind: "saved-workspace",
            workspace: selection.workspace,
            activeChat: binding,
          });
        } else {
          void focusChat(binding);
        }
        return;
      }

      const referencePanelId =
        options?.referenceBinding != null
          ? createChatPanelId(options.referenceBinding)
          : createChatPanelId(
              selection.kind === "single-chat"
                ? selection.chat
                : getActiveOuterBinding(api) ??
                    extractBindingsFromSerializedLayout(api.toJSON())[0] ??
                    binding,
            );

      addOuterChatPanel(api, binding, {
        position: options?.position ?? "right",
        referencePanel: referencePanelId,
      });

      if (selection.kind === "single-chat") {
        const layout = api.toJSON();
        const layoutJson = serializeDockviewLayout(layout);
        const detail = await desktopClient.createSavedWorkspace({
          chats: extractBindingsFromSerializedLayout(layout),
          layoutJson,
        });
        markPersistedLayout(layoutJson, detail.id);
        setSelection({
          kind: "saved-workspace",
          workspace: detail,
          activeChat: binding,
        });
      } else if (selection.kind === "saved-workspace") {
        setSelection({
          kind: "saved-workspace",
          workspace: selection.workspace,
          activeChat: binding,
        });
        persistSavedWorkspaceLayout();
      } else {
        void focusChat(binding);
      }
    },
    [
      addOuterChatPanel,
      focusChat,
      markPersistedLayout,
      persistSavedWorkspaceLayout,
      selection,
      setSelection,
    ],
  );

  useEffect(
    () =>
      sessionStore.subscribe((state) => {
        const currentSelection = state.selection;
        selectionRef.current = currentSelection;
        if (
          currentSelection.kind !== "saved-workspace" ||
          currentSelection.activeChat == null
        ) {
          return;
        }

        const api = outerApiRef.current;
        if (api == null) {
          return;
        }

        const panelId = createChatPanelId(currentSelection.activeChat);
        const existingPanel = api.getPanel(panelId);
        if (existingPanel != null) {
          if (api.activePanel?.id !== panelId) {
            existingPanel.focus();
          }
          return;
        }

        const referenceBinding =
          getActiveOuterBinding(api) ??
          extractBindingsFromSerializedLayout(api.toJSON())[0] ??
          currentSelection.activeChat;

        addOuterChatPanel(api, currentSelection.activeChat, {
          position: "right",
          referencePanel: createChatPanelId(referenceBinding),
        });
        persistSavedWorkspaceLayout();
      }),
    [addOuterChatPanel, persistSavedWorkspaceLayout],
  );

  const handleOuterReady = useCallback(
    (event: DockviewReadyEvent) => {
      disposablesRef.current.forEach((disposable) => disposable.dispose());
      disposablesRef.current = [];
      outerApiRef.current = event.api;
      disposablesRef.current = [
        event.api.onDidActivePanelChange((panel) => {
          const binding = getOuterPanelBinding(panel);
          const currentSelection = selectionRef.current;
          if (binding == null || currentSelection.kind !== "saved-workspace") {
            return;
          }

          if (areChatBindingsEqual(currentSelection.activeChat, binding)) {
            return;
          }

          setSelection({
            kind: "saved-workspace",
            workspace: currentSelection.workspace,
            activeChat: binding,
          });
          void ensureConversationViewLoaded(binding);
        }),
        event.api.onDidLayoutChange(() => {
          applyOuterLayoutConstraints(event.api);
          persistSavedWorkspaceLayout();
        }),
        event.api.onUnhandledDragOverEvent((dragEvent) => {
          if (hasChatBindingDataTransfer(dragEvent.nativeEvent.dataTransfer)) {
            dragEvent.accept();
          }
        }),
      ];

      void restoreSelection(event.api);
    },
    [
      applyOuterLayoutConstraints,
      persistSavedWorkspaceLayout,
      restoreSelection,
      setSelection,
    ],
  );

  const components = useMemo(
    () => ({
      [OUTER_CHAT_COMPONENT]: function ChatTilePanel({
        params,
      }: IDockviewPanelProps<OuterChatPanelParams>) {
        const binding = {
          workspacePath: params.workspacePath,
          conversationId: params.conversationId,
        };

        return (
          <ChatTile
            binding={binding}
            canCloseChat={() => canCloseChatPanel(binding)}
            onCloseChat={() => {
              closeChatPanel(binding);
            }}
          />
        );
      },
    }),
    [canCloseChatPanel, closeChatPanel],
  );

  const handleOuterDidDrop = useCallback(
    (event: Parameters<NonNullable<React.ComponentProps<typeof DockviewReact>["onDidDrop"]>>[0]) => {
      const binding = readChatBindingFromDataTransfer(
        event.nativeEvent.dataTransfer,
      );
      if (binding == null) {
        clearActiveDraggedChatBinding();
        return;
      }

      const referenceBinding =
        event.group?.activePanel != null
          ? getOuterPanelBinding(event.group.activePanel)
          : getActiveOuterBinding(outerApiRef.current);
      const position =
        event.position === "left" ? "left" : "right";

      void addChatToBoard(
        binding,
        referenceBinding == null
          ? undefined
          : {
              referenceBinding,
              position,
            },
      );
      clearActiveDraggedChatBinding();
    },
    [addChatToBoard],
  );

  if (selection.kind === "empty") {
    return <NewChatScreen />;
  }

  if (selection.kind === "workspace-draft") {
    return <ConversationPanel />;
  }

  return (
    <section className="workspace-board relative flex h-full min-h-0 min-w-0 flex-1 overflow-hidden">
      <DockviewReact
        key={`${selectionKey}:${layoutResetNonce}`}
        className="workspace-board-dock h-full w-full"
        components={components}
        disableFloatingGroups
        dndEdges={{
          activationSize: { value: 24, type: "pixels" },
          size: { value: 24, type: "pixels" },
        }}
        onDidDrop={handleOuterDidDrop}
        onReady={handleOuterReady}
        onWillDrop={(dropEvent) => {
          const internalDropData = dropEvent.getData();

          if (
            dropEvent.position === "center" ||
            dropEvent.position === "top" ||
            dropEvent.position === "bottom"
          ) {
            dropEvent.preventDefault();
            return;
          }

          if (
            internalDropData != null &&
            (
              internalDropData.groupId === dropEvent.group?.id ||
              internalDropData.panelId === dropEvent.panel?.id
            )
          ) {
            dropEvent.preventDefault();
          }
        }}
        singleTabMode="fullwidth"
        theme={theme}
      />
    </section>
  );
}
