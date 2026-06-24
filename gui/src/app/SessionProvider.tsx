import { useCallback, useEffect, useMemo } from "react";
import { useStore } from "zustand";

import * as desktopClient from "../services/desktop/client";
import type {
  ChatBinding,
  HandoffChatInput,
  SessionSnapshot,
} from "../services/desktop/types/contracts";
import { extractBindingsFromLayoutJson } from "../components/workspace-board/layout";
import { SessionActionsContext } from "./SessionContext";
import type { SubmitPromptInput } from "./types/sessionContext";
import {
  openWorkspaceInTarget,
  runWorkspaceRuntimeStatusAction,
  submitFollowupResponse,
  updateWorkspacePromptSettings,
} from "./sessionClientActions";
import {
  beginConversationSelectionRequest,
  areSelectionsEqual,
  ensureConversationViewLoaded,
  ensureWorkspacePromptSettingsLoaded,
  ensureWorkspaceRuntimeStatusLoaded,
  getAttachments,
  getConversationSummary,
  getConversationView,
  getSelectionFromSnapshot,
  isLatestConversationSelectionRequest,
  getPromptDraftState,
  getUiActiveBinding,
  getUiActiveConversationId,
  getUiActiveWorkspacePath,
  sessionStore,
} from "./sessionStore";
import {
  getPromptDraftKey,
  getWorkspaceDraftKey,
  LATEST_WORKSPACE_STORAGE_KEY,
} from "./sessionSnapshot";
import { appendAttachmentsToPrompt } from "@/components/attachments/attachmentTypes";
import {
  isActivePromptConflictError,
  snapshotHasActiveRequest,
} from "./promptSubmitErrors";
import {
  finishPromptQueueDrain,
  tryBeginPromptQueueDrain,
} from "./promptQueueDrain";
import type { SessionProviderProps } from "./types/app";
import { useSessionBootstrap } from "../hooks/useSessionBootstrap";

function snapshotHasConversationView(
  snapshot: SessionSnapshot,
  binding: ChatBinding,
) {
  return snapshot.conversationViews.some(
    (view) =>
      view.workspacePath === binding.workspacePath &&
      view.conversationId === binding.conversationId,
  );
}

export function SessionProvider({ children }: SessionProviderProps) {
  const activeWorkspacePath = useStore(sessionStore, (state) =>
    getUiActiveWorkspacePath(state),
  );

  const applySessionSnapshot = useCallback((snapshot: SessionSnapshot) => {
    const store = sessionStore.getState();
    store.applySessionSnapshot(snapshot);
    store.setIsBootstrapped(true);
  }, []);

  const markSessionBootstrapped = useCallback(() => {
    sessionStore.getState().setIsBootstrapped(true);
  }, []);

  const syncBoardSelectionFromSnapshot = useCallback(
    (snapshot: SessionSnapshot) => {
      sessionStore
        .getState()
        .setBoardSelection(getSelectionFromSnapshot(snapshot));
    },
    [],
  );

  const runSnapshotCommand = useCallback(
    async (command: () => Promise<SessionSnapshot>) => {
      try {
        return await command();
      } catch {
        return null;
      }
    },
    [],
  );

  useSessionBootstrap({
    setSessionSnapshot: applySessionSnapshot,
    onReady: markSessionBootstrapped,
  });

  useEffect(() => {
    if (activeWorkspacePath == null) {
      return;
    }

    const activeWorkspace = sessionStore
      .getState()
      .workspaces.find(
        (workspace) => workspace.workspacePath === activeWorkspacePath,
      );
    if (activeWorkspace?.kind === "managed_chat") {
      window.localStorage.removeItem(LATEST_WORKSPACE_STORAGE_KEY);
      return;
    }

    window.localStorage.setItem(
      LATEST_WORKSPACE_STORAGE_KEY,
      activeWorkspacePath,
    );
  }, [activeWorkspacePath]);

  const ensureWorkspaceMeta = useCallback(
    (workspacePath: string, options?: { forceRuntimeStatus?: boolean }) => {
      void ensureWorkspaceRuntimeStatusLoaded(workspacePath, {
        force: options?.forceRuntimeStatus,
      });
      void ensureWorkspacePromptSettingsLoaded(workspacePath);
    },
    [],
  );

  const findReusableManagedChatDraft = useCallback(() => {
    const store = sessionStore.getState();
    return (
      store.workspaces.find(
        (workspace) =>
          workspace.kind === "managed_chat" &&
          workspace.selectedConversationId == null &&
          workspace.conversations.length === 0,
      ) ?? null
    );
  }, []);

  const openWorkspaceByPath = useCallback(
    async (workspacePath: string) => {
      const store = sessionStore.getState();
      store.setIsOpeningProject(true);
      try {
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.openWorkspace(workspacePath),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
        syncBoardSelectionFromSnapshot(snapshot);
        ensureWorkspaceMeta(workspacePath, { forceRuntimeStatus: true });
      } finally {
        sessionStore.getState().setIsOpeningProject(false);
      }
    },
    [
      applySessionSnapshot,
      ensureWorkspaceMeta,
      runSnapshotCommand,
      syncBoardSelectionFromSnapshot,
    ],
  );

  // `codegraff <path>` (code-style): open the path the launcher handed us —
  // either stashed before launch (cold start) or forwarded to this running
  // instance (single-instance). No-op in the browser/QA mock.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void (async () => {
      try {
        const pending = await desktopClient.drainPendingOpen();
        if (!cancelled && pending) {
          void openWorkspaceByPath(pending);
        }
      } catch {
        // No pending path (or native bridge unavailable) — ignore.
      }
      try {
        unlisten = await desktopClient.onOpenWorkspacePath((path) => {
          void openWorkspaceByPath(path);
        });
      } catch {
        // Event bridge unavailable (browser mode) — ignore.
      }
    })();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [openWorkspaceByPath]);

  const actionState = useMemo(
    () => ({
      checkoutBranch: async (branchName: string) => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.checkoutGitBranch({
            branchName,
            workspacePath,
          }),
        );
      },
      commitChanges: async (message: string) => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.commitGitChanges({
            message,
            workspacePath,
          }),
        );
      },
      createBranch: async (branchName: string) => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.createGitBranch({
            branchName,
            workspacePath,
          }),
        );
      },
      openInTarget: async (targetId: string) => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await openWorkspaceInTarget(workspacePath, targetId);
      },
      openProject: async (workspacePath: string) => {
        await openWorkspaceByPath(workspacePath);
      },
      archiveConversation: async (
        workspacePath: string,
        conversationId: string,
      ) => {
        const currentSelection = sessionStore.getState().selection;
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.archiveConversation(workspacePath, conversationId),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
        const activeBinding =
          currentSelection.kind === "single-chat"
            ? currentSelection.chat
            : currentSelection.kind === "saved-workspace"
              ? currentSelection.activeChat
              : null;
        if (
          activeBinding?.workspacePath === workspacePath &&
          activeBinding.conversationId === conversationId
        ) {
          syncBoardSelectionFromSnapshot(snapshot);
        }
      },
      archiveWorkspace: async (workspacePath: string) => {
        const currentWorkspacePath = getUiActiveWorkspacePath(
          sessionStore.getState(),
        );
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.archiveWorkspace(workspacePath),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
        if (currentWorkspacePath === workspacePath) {
          syncBoardSelectionFromSnapshot(snapshot);
        }
      },
      renameWorkspace: async (
        workspacePath: string,
        displayName?: string | null,
      ) => {
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.renameWorkspace(workspacePath, displayName ?? null),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
      },
      renameSavedWorkspace: async (workspaceId: string, name: string) => {
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.renameSavedWorkspace(workspaceId, name),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
      },
      deleteSavedWorkspace: async (workspaceId: string) => {
        const selection = sessionStore.getState().selection;
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.deleteSavedWorkspace(workspaceId),
        );
        if (snapshot == null) {
          return;
        }

        applySessionSnapshot(snapshot);
        if (
          selection.kind === "saved-workspace" &&
          selection.workspace.id === workspaceId
        ) {
          syncBoardSelectionFromSnapshot(snapshot);
        }
      },
      openSavedWorkspace: async (workspaceId: string) => {
        const workspace = await desktopClient
          .getSavedWorkspace(workspaceId)
          .catch(() => null);
        if (workspace == null) {
          return;
        }

        const bindings = extractBindingsFromLayoutJson(workspace.layoutJson);
        const initialBinding = bindings[0] ?? null;
        sessionStore.getState().setBoardSelection({
          kind: "saved-workspace",
          workspace,
          activeChat: initialBinding,
        });

        if (initialBinding == null) {
          return;
        }

        ensureWorkspaceMeta(initialBinding.workspacePath);
        await ensureConversationViewLoaded(initialBinding);

        const snapshot = await runSnapshotCommand(() =>
          desktopClient.selectConversation(
            initialBinding.workspacePath,
            initialBinding.conversationId,
          ),
        );
        if (snapshot != null) {
          applySessionSnapshot(snapshot);
        }
      },
      openWorkspacePicker: async () => {
        try {
          const selectedPath = await desktopClient.pickWorkspace();
          if (selectedPath == null) {
            return null;
          }

          await openWorkspaceByPath(selectedPath);
          return selectedPath;
        } catch {
          return null;
        }
      },
      pushBranch: async () => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.pushGitBranch(workspacePath),
        );
      },
      handoffChat: async (input: HandoffChatInput) => {
        const originPromptDraftKey = getPromptDraftKey(
          input.sourceWorkspacePath,
          input.conversationId,
        );
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.handoffChat(input),
        );
        if (snapshot == null) {
          return null;
        }

        applySessionSnapshot(snapshot);
        syncBoardSelectionFromSnapshot(snapshot);

        const nextPromptDraftKey = getPromptDraftKey(
          snapshot.activeWorkspacePath,
          snapshot.activeConversationId,
        );
        sessionStore
          .getState()
          .movePromptDraft(originPromptDraftKey, nextPromptDraftKey);

        if (snapshot.activeWorkspacePath != null) {
          ensureWorkspaceMeta(snapshot.activeWorkspacePath, {
            forceRuntimeStatus: true,
          });
        }

        return snapshot;
      },
      selectConversation: async (
        workspacePath: string,
        conversationId: string,
      ) => {
        const requestId = beginConversationSelectionRequest();
        const previousSelection = sessionStore.getState().selection;

        const binding = { conversationId, workspacePath } satisfies ChatBinding;
        const optimisticSelection = {
          kind: "single-chat",
          chat: binding,
        } as const;

        ensureWorkspaceMeta(workspacePath);

        sessionStore.getState().setBoardSelection(optimisticSelection);

        const revertOptimisticSelection = () => {
          const store = sessionStore.getState();
          if (
            isLatestConversationSelectionRequest(requestId) &&
            areSelectionsEqual(store.selection, optimisticSelection)
          ) {
            store.setBoardSelection(previousSelection);
          }
        };

        try {
          const snapshot = await desktopClient.selectConversation(
            workspacePath,
            conversationId,
          );
          if (!isLatestConversationSelectionRequest(requestId)) {
            return;
          }

          // The harness can report the target as active without ever sending its
          // conversation view (e.g. a draft that was discarded). Selecting it
          // would leave the board pointing at an empty chat, so revert.
          if (
            snapshot.activeWorkspacePath === workspacePath &&
            snapshot.activeConversationId === conversationId &&
            !snapshotHasConversationView(snapshot, binding)
          ) {
            revertOptimisticSelection();
            return;
          }

          applySessionSnapshot(snapshot);
          ensureWorkspaceMeta(workspacePath, { forceRuntimeStatus: true });
        } catch {
          revertOptimisticSelection();
          return;
        }
      },
      startNewChat: async (workspacePath?: string) => {
        const targetWorkspacePath = workspacePath ?? null;
        if (targetWorkspacePath == null) {
          const reusableManagedChatDraft = findReusableManagedChatDraft();
          if (reusableManagedChatDraft != null) {
            await openWorkspaceByPath(reusableManagedChatDraft.workspacePath);
            return null;
          }

          const snapshot = await runSnapshotCommand(() =>
            desktopClient.createManagedChat(),
          );
          if (snapshot == null) {
            return null;
          }

          applySessionSnapshot(snapshot);
          if (
            snapshot.activeWorkspacePath != null &&
            snapshot.activeConversationId == null
          ) {
            sessionStore.getState().setBoardSelection({
              kind: "workspace-draft",
              workspacePath: snapshot.activeWorkspacePath,
            });
            ensureWorkspaceMeta(snapshot.activeWorkspacePath, {
              forceRuntimeStatus: true,
            });
          }
          return snapshot;
        }

        const originPromptDraftKey = getWorkspaceDraftKey(targetWorkspacePath);
        const snapshot = await runSnapshotCommand(() =>
          desktopClient.startNewChat(targetWorkspacePath),
        );
        if (snapshot == null) {
          return null;
        }

        applySessionSnapshot(snapshot);
        const nextPromptDraftKey = getPromptDraftKey(
          snapshot.activeWorkspacePath,
          snapshot.activeConversationId,
        );
        sessionStore
          .getState()
          .movePromptDraft(originPromptDraftKey, nextPromptDraftKey);

        if (
          snapshot.activeWorkspacePath === targetWorkspacePath &&
          snapshot.activeConversationId == null
        ) {
          sessionStore.getState().setBoardSelection({
            kind: "workspace-draft",
            workspacePath: targetWorkspacePath,
          });
        }

        ensureWorkspaceMeta(targetWorkspacePath, {
          forceRuntimeStatus: true,
        });
        return snapshot;
      },
      submitFollowup: async (input: {
        cancelled: boolean;
        text?: string;
        selectedOptionIds?: string[];
      }) => {
        const activeBinding = getUiActiveBinding(sessionStore.getState());
        const followupRequest =
          activeBinding == null
            ? null
            : (getConversationView(activeBinding)?.followup ?? null);
        if (followupRequest == null) {
          return;
        }

        await submitFollowupResponse({
          cancelled: input.cancelled,
          followupId: followupRequest.followupId,
          selectedOptionIds: input.selectedOptionIds,
          text: input.text,
        });
      },
      stopPrompt: async () => {
        const activeBinding = getUiActiveBinding(sessionStore.getState());
        if (activeBinding == null) {
          return;
        }

        await desktopClient.stopPrompt(activeBinding).catch(() => null);
        sessionStore
          .getState()
          .setPromptDraftPending(
            getPromptDraftKey(
              activeBinding.workspacePath,
              activeBinding.conversationId,
            ),
            false,
          );
        await desktopClient
          .getSessionSnapshot()
          .then(applySessionSnapshot)
          .catch(() => null);
      },
      submitPrompt: async (input?: SubmitPromptInput) => {
        const state = sessionStore.getState();
        const workspacePath =
          typeof input === "object" && input != null && "workspacePath" in input
            ? input.workspacePath ?? null
            : getUiActiveWorkspacePath(state);
        if (workspacePath == null) {
          return;
        }

        const conversationId =
          typeof input === "object" && input != null && "conversationId" in input
            ? input.conversationId ?? null
            : getUiActiveConversationId(state);
        const promptDraftKey = getPromptDraftKey(workspacePath, conversationId);
        if (promptDraftKey == null) {
          return;
        }

        const draftState = getPromptDraftState(promptDraftKey);
        const draftValue = typeof input === "string" ? input : input?.draft ?? draftState.value;
        const trimmedPrompt = draftValue.trim();
        if (trimmedPrompt.length === 0) {
          return;
        }

        // Attachments dropped in a new chat are stored under this draft key;
        // append them so they ride the first message, mirroring the bound-chat
        // submit path in useConversationActions.
        const attachments = getAttachments(promptDraftKey);
        const targetBinding =
          conversationId == null ? null : { workspacePath, conversationId };
        const targetIsKnownRunning =
          targetBinding != null &&
          ((getConversationView(targetBinding)?.activeRequestIds.length ?? 0) > 0 ||
            (getConversationSummary(targetBinding)?.isRunning ?? false));
        if (targetIsKnownRunning) {
          const store = sessionStore.getState();
          store.enqueuePrompt(promptDraftKey, {
            attachments,
            isPlanningMode: draftState.isPlanningMode,
            isUltraMode: draftState.isUltraMode,
            value: trimmedPrompt,
          });
          store.clearPromptDraft(promptDraftKey);
          store.setPromptDraftUltraMode(promptDraftKey, false);
          store.clearAttachments(promptDraftKey);
          return;
        }
        const prompt = appendAttachmentsToPrompt(trimmedPrompt, attachments);
        const restorePromptDraft = () => {
          const store = sessionStore.getState();
          store.setPromptDraftValue(promptDraftKey, draftValue);
          store.setPromptDraftPlanningMode(
            promptDraftKey,
            draftState.isPlanningMode,
          );
          store.setPromptDraftUltraMode(promptDraftKey, draftState.isUltraMode);
          store.clearAttachments(promptDraftKey);
          store.addAttachments(promptDraftKey, attachments);
        };
        // Clear the welcome composer immediately on send (prompt already
        // captured) so the draft + attachment don't linger while the turn runs.
        sessionStore.getState().clearPromptDraft(promptDraftKey);
        sessionStore.getState().clearAttachments(promptDraftKey);

        let nextPromptDraftKey: string | null = promptDraftKey;
        const agentId = draftState.isPlanningMode ? "muse" : "forge";
        const store = sessionStore.getState();
        const optimisticRequestId = `optimistic-${Date.now()}`;
        const optimisticBinding = {
          conversationId: conversationId ?? `optimistic-chat-${Date.now()}`,
          workspacePath,
        };
        store.setPromptDraftPending(promptDraftKey, true);
        store.appendOptimisticUserMessage(
          optimisticBinding,
          optimisticRequestId,
          prompt,
          agentId,
        );

        const snapshot = await desktopClient
          .sendPrompt({
            agentId,
            conversationId,
            prompt,
            workspacePath,
          })
          .catch(async (error) => {
            const currentStore = sessionStore.getState();
            currentStore.removeOptimisticRequest(
              optimisticBinding,
              optimisticRequestId,
            );
            if (isActivePromptConflictError(error)) {
              const conflictBinding =
                conversationId == null ? null : { workspacePath, conversationId };
              const refreshedSnapshot = await desktopClient
                .getSessionSnapshot()
                .catch(() => null);
              if (refreshedSnapshot != null) {
                applySessionSnapshot(refreshedSnapshot);
              }
              if (
                conflictBinding != null &&
                snapshotHasActiveRequest(refreshedSnapshot, conflictBinding)
              ) {
                sessionStore.getState().enqueuePrompt(promptDraftKey, {
                  attachments,
                  isPlanningMode: draftState.isPlanningMode,
                  isUltraMode: draftState.isUltraMode,
                  value: trimmedPrompt,
                });
                return null;
              }
            }
            restorePromptDraft();
            return null;
          });
        if (snapshot == null) {
          sessionStore.getState().setPromptDraftPending(promptDraftKey, false);
          return;
        }
        if (snapshot != null) {
          applySessionSnapshot(snapshot);
          nextPromptDraftKey = getPromptDraftKey(
            snapshot.activeWorkspacePath,
            snapshot.activeConversationId,
          );
          // Carry both the text draft and any attachments across the
          // workspace:<path> -> conversation:<id> key change, then clear them so
          // the materialized chat starts with an empty composer.
          sessionStore
            .getState()
            .movePromptDraft(promptDraftKey, nextPromptDraftKey);
          sessionStore
            .getState()
            .moveAttachments(promptDraftKey, nextPromptDraftKey);
          sessionStore.getState().clearPromptDraft(nextPromptDraftKey);
          sessionStore.getState().clearAttachments(nextPromptDraftKey);
        }

        sessionStore.getState().setPromptDraftPending(promptDraftKey, false);
        if (nextPromptDraftKey !== promptDraftKey) {
          sessionStore
            .getState()
            .setPromptDraftPending(nextPromptDraftKey, false);
        }
      },
      updatePromptSettings: async (input: {
        providerId: string;
        modelId: string;
        reasoningEffort?: string | null;
      }) => {
        const workspacePath = getUiActiveWorkspacePath(sessionStore.getState());
        if (workspacePath == null) {
          return;
        }

        await updateWorkspacePromptSettings(workspacePath, input);
      },
    }),
    [
      applySessionSnapshot,
      ensureWorkspaceMeta,
      findReusableManagedChatDraft,
      openWorkspaceByPath,
      runSnapshotCommand,
      syncBoardSelectionFromSnapshot,
    ],
  );

  useEffect(() => {
    return sessionStore.subscribe((state) => {
      const binding = getUiActiveBinding(state);
      if (binding == null) {
        return;
      }
      const promptDraftKey = getPromptDraftKey(
        binding.workspacePath,
        binding.conversationId,
      );
      if (promptDraftKey == null) {
        return;
      }

      const next = tryBeginPromptQueueDrain(promptDraftKey, binding);
      if (next == null) {
        return;
      }
      const store = sessionStore.getState();
      store.setPromptDraftValue(promptDraftKey, next.value);
      store.setPromptDraftPlanningMode(promptDraftKey, next.isPlanningMode);
      store.setPromptDraftUltraMode(promptDraftKey, next.isUltraMode);
      store.clearAttachments(promptDraftKey);
      store.addAttachments(promptDraftKey, next.attachments);
      queueMicrotask(() => {
        void actionState
          .submitPrompt({
            conversationId: binding.conversationId,
            draft: next.value,
            workspacePath: binding.workspacePath,
          })
          .finally(() => {
            finishPromptQueueDrain(promptDraftKey);
          });
      });
    });
  }, [actionState]);

  return (
    <SessionActionsContext.Provider value={actionState}>
      {children}
    </SessionActionsContext.Provider>
  );
}
