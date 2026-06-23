import { useCallback, useContext, useEffect, useMemo } from "react";
import { useStore } from "zustand";
import { useShallow } from "zustand/react/shallow";

import { SessionActionsContext } from "../app/SessionContext";
import { getPromptDraftKey } from "../app/sessionSnapshot";
import {
  ensureWorkspacePromptSettingsLoaded,
  ensureWorkspaceRuntimeStatusLoaded,
  getConversationStoreKey,
  getUiActiveConversationId,
  getUiActiveWorkspacePath,
  getUiWorkspaceLabel,
  getWorkspaceMetaStoreKey,
  sessionStore,
} from "../app/sessionStore";
import type {
  QueuedPromptEntry,
  SessionStoreState,
  WorkspaceMetaState,
} from "../app/types/sessionStore";
import type { WorkspaceBoardSelection } from "../app/types/sessionContext";
import type { Attachment } from "../components/attachments/attachmentTypes";
import { getWorkspaceBoardSelectionKey } from "../components/workspace-board/workspaceBoardUtils";
import type { ChatBinding } from "../services/desktop/types/contracts";

const EMPTY_REQUEST_TIMINGS = {};
const EMPTY_REQUEST_AGENT_IDS: Record<string, string> = {};
const EMPTY_STRING_ARRAY: string[] = [];
const EMPTY_ATTACHMENTS: Attachment[] = [];
const EMPTY_QUEUED_PROMPTS: QueuedPromptEntry[] = [];
const EMPTY_MESSAGES: Array<
  import("../services/desktop/types/contracts").TranscriptMessage
> = [];
const EMPTY_TODOS: Array<
  import("../services/desktop/types/contracts").SessionTodo
> = [];
const EMPTY_WORKSPACE_META: WorkspaceMetaState = {
  promptSettings: null,
  promptSettingsLoaded: false,
  runtimeStatus: null,
  runtimeStatusLoaded: false,
};

function useRequiredContext<T>(value: T | null, name: string): T {
  if (value == null) {
    throw new Error(`${name} must be used within a SessionProvider`);
  }

  return value;
}

function getScopedWorkspacePath(
  state: Pick<SessionStoreState, "activeWorkspacePath" | "selection">,
  binding: ChatBinding | null | undefined,
): string | null {
  return binding?.workspacePath ?? getUiActiveWorkspacePath(state);
}

function getScopedConversationId(
  state: Pick<SessionStoreState, "activeConversationId" | "selection">,
  binding: ChatBinding | null | undefined,
): string | null {
  return binding?.conversationId ?? getUiActiveConversationId(state);
}

function getScopedConversationView(
  state: SessionStoreState,
  binding: ChatBinding | null | undefined,
) {
  const workspacePath = getScopedWorkspacePath(state, binding);
  const conversationId = getScopedConversationId(state, binding);
  if (workspacePath == null || conversationId == null) {
    return null;
  }

  return (
    state.conversationViewsByKey[
      getConversationStoreKey(workspacePath, conversationId)
    ] ?? null
  );
}

function getScopedConversationSummary(
  state: SessionStoreState,
  binding: ChatBinding | null | undefined,
) {
  const workspacePath = getScopedWorkspacePath(state, binding);
  const conversationId = getScopedConversationId(state, binding);
  if (workspacePath == null || conversationId == null) {
    return null;
  }

  return (
    state.conversationSummariesByKey[
      getConversationStoreKey(workspacePath, conversationId)
    ] ?? null
  );
}

function isWorkspaceConfigured(
  meta: WorkspaceMetaState,
  workspace: ReturnType<typeof getScopedWorkspace>,
): boolean {
  if (meta.runtimeStatus != null) {
    return meta.runtimeStatus.configured;
  }

  if ((meta.promptSettings?.availableModels.length ?? 0) > 0) {
    return true;
  }

  return workspace?.configured ?? true;
}

function getScopedWorkspace(
  state: SessionStoreState,
  binding: ChatBinding | null | undefined,
) {
  const workspacePath = getScopedWorkspacePath(state, binding);
  return workspacePath == null
    ? null
    : (state.workspacesByPath[workspacePath] ?? null);
}

export function useSessionActions() {
  return useRequiredContext(
    useContext(SessionActionsContext),
    "useSessionActions",
  );
}

export function useSessionStore<T>(
  selector: (state: SessionStoreState) => T,
): T {
  return useStore(sessionStore, selector);
}

export function useBoardSelection(): WorkspaceBoardSelection {
  return useSessionStore((state) => state.selection);
}

export function useBoardSelectionKey(): string {
  return useSessionStore((state) =>
    getWorkspaceBoardSelectionKey(state.selection),
  );
}

export function useWorkspaceMeta(
  workspacePath: string | null,
): WorkspaceMetaState {
  const workspaceMetaKey = getWorkspaceMetaStoreKey(workspacePath);
  const meta = useSessionStore(
    (state) =>
      state.workspaceMetaByKey[workspaceMetaKey] ?? EMPTY_WORKSPACE_META,
  );

  useEffect(() => {
    void ensureWorkspaceRuntimeStatusLoaded(workspacePath);
    if (workspacePath != null) {
      void ensureWorkspacePromptSettingsLoaded(workspacePath);
    }
  }, [workspacePath]);

  return meta;
}

export function useWorkspaceSession(workspacePath: string | null) {
  return useSessionStore((state) =>
    workspacePath == null
      ? null
      : (state.workspacesByPath[workspacePath] ?? null),
  );
}

export function useConversationView(binding: ChatBinding | null | undefined) {
  return useSessionStore((state) => getScopedConversationView(state, binding));
}

export function useConversationSummary(
  binding: ChatBinding | null | undefined,
) {
  return useSessionStore((state) =>
    getScopedConversationSummary(state, binding),
  );
}

export function useHasCurrentWorkspace(): boolean {
  return useSessionStore((state) => getUiActiveWorkspacePath(state) != null);
}

export function useSidebarSession() {
  return useSessionStore(
    useShallow((state) => {
      const activeWorkspacePath = getUiActiveWorkspacePath(state);
      const activeConversationId = getUiActiveConversationId(state);
      return {
        activeConversationId,
        activeSavedWorkspaceId:
          state.selection.kind === "saved-workspace"
            ? state.selection.workspace.id
            : null,
        activeWorkspacePath,
        hasCurrentWorkspace: activeWorkspacePath != null,
        savedWorkspaces: state.savedWorkspaces,
        workspaces: state.workspaces,
      };
    }),
  );
}

export function useConversationSession(binding?: ChatBinding | null) {
  const workspacePath = useSessionStore((state) =>
    getScopedWorkspacePath(state, binding),
  );
  const meta = useWorkspaceMeta(workspacePath);

  return useSessionStore(
    useShallow((state) => {
      const currentWorkspacePath = getScopedWorkspacePath(state, binding);
      const currentConversationId = getScopedConversationId(state, binding);
      const currentWorkspace = getScopedWorkspace(state, binding);
      const currentView = getScopedConversationView(state, binding);

      return {
        activeRequestIds: currentView?.activeRequestIds ?? EMPTY_STRING_ARRAY,
        activeWorkspaceConfigurationError:
          meta.runtimeStatus?.configurationError ??
          currentWorkspace?.configurationError ??
          null,
        activeWorkspaceConfigured: isWorkspaceConfigured(
          meta,
          currentWorkspace,
        ),
        activeWorkspaceLabel: getUiWorkspaceLabel(
          currentWorkspacePath,
          meta.runtimeStatus,
        ),
        followupRequest: currentView?.followup ?? null,
        goal: currentView?.goal ?? null,
        hasCurrentWorkspace: currentWorkspacePath != null,
        // An existing conversation is selected but its view (messages) has not
        // streamed in yet. Used to show a loading placeholder instead of
        // briefly flashing the empty new-chat screen. A genuine new chat has a
        // null conversationId, so it is never considered "loading".
        isConversationLoading:
          currentConversationId != null && currentView == null,
        isOpeningProject: state.isOpeningProject,
        conversationVersion:
          currentWorkspacePath == null || currentConversationId == null
            ? 0
            : (state.conversationVersionsByKey[
                getConversationStoreKey(currentWorkspacePath, currentConversationId)
              ] ?? 0),
        messages: currentView?.messages ?? EMPTY_MESSAGES,
        requestAgentIds:
          currentView?.requestAgentIds ?? EMPTY_REQUEST_AGENT_IDS,
        requestTimingsById:
          currentConversationId == null
            ? EMPTY_REQUEST_TIMINGS
            : (state.requestTimingsByConversationId[currentConversationId] ??
              EMPTY_REQUEST_TIMINGS),
        runtimeStatus: meta.runtimeStatus,
        todos: currentView?.todos ?? EMPTY_TODOS,
        uiError: state.uiError,
        workspaceKind: currentWorkspace?.kind ?? "project",
        workspacePath: currentWorkspacePath,
      };
    }),
  );
}

export function useAttachments(binding?: ChatBinding | null) {
  const promptDraftKey = useSessionStore((state) =>
    getPromptDraftKey(
      getScopedWorkspacePath(state, binding),
      getScopedConversationId(state, binding),
    ),
  );
  const attachments = useSessionStore((state) =>
    promptDraftKey == null
      ? EMPTY_ATTACHMENTS
      : (state.attachmentsByKey[promptDraftKey] ?? EMPTY_ATTACHMENTS),
  );
  const addAttachments = useCallback(
    (items: Attachment[]) => {
      sessionStore.getState().addAttachments(promptDraftKey, items);
    },
    [promptDraftKey],
  );
  const removeAttachment = useCallback(
    (id: string) => {
      sessionStore.getState().removeAttachment(promptDraftKey, id);
    },
    [promptDraftKey],
  );
  // Swap the whole tray in one shot (used by prompt-history navigation to
  // rehydrate a restored prompt's attachments).
  const replaceAttachments = useCallback(
    (items: Attachment[]) => {
      sessionStore.getState().clearAttachments(promptDraftKey);
      if (items.length > 0) {
        sessionStore.getState().addAttachments(promptDraftKey, items);
      }
    },
    [promptDraftKey],
  );

  return useMemo(
    () => ({ attachments, addAttachments, removeAttachment, replaceAttachments }),
    [attachments, addAttachments, removeAttachment, replaceAttachments],
  );
}

export function usePromptDraft(binding?: ChatBinding | null) {
  const workspacePath = useSessionStore((state) =>
    getScopedWorkspacePath(state, binding),
  );
  const promptDraftKey = useSessionStore((state) =>
    getPromptDraftKey(
      getScopedWorkspacePath(state, binding),
      getScopedConversationId(state, binding),
    ),
  );
  const meta = useWorkspaceMeta(workspacePath);
  const setPromptDraft = useCallback(
    (value: string) => {
      sessionStore.getState().setPromptDraftValue(promptDraftKey, value);
    },
    [promptDraftKey],
  );
  const setPlanningMode = useCallback(
    (value: boolean) => {
      sessionStore.getState().setPromptDraftPlanningMode(promptDraftKey, value);
    },
    [promptDraftKey],
  );
  const setUltraMode = useCallback(
    (value: boolean) => {
      sessionStore.getState().setPromptDraftUltraMode(promptDraftKey, value);
    },
    [promptDraftKey],
  );

  const draftState = useSessionStore(
    useShallow((state) => {
      const currentWorkspacePath = getScopedWorkspacePath(state, binding);
      const currentConversationId = getScopedConversationId(state, binding);
      const scopedPromptDraftKey = getPromptDraftKey(
        currentWorkspacePath,
        currentConversationId,
      );
      const draftEntry =
        scopedPromptDraftKey == null
          ? null
          : (state.promptDraftsByKey[scopedPromptDraftKey] ?? null);
      const currentWorkspace = getScopedWorkspace(state, binding);
      const currentView = getScopedConversationView(state, binding);
      const followupRequest = currentView?.followup ?? null;
      const activeWorkspaceConfigured = isWorkspaceConfigured(
        meta,
        currentWorkspace,
      );

      return {
        canCompose:
          currentWorkspacePath != null &&
          activeWorkspaceConfigured &&
          followupRequest == null &&
          (draftEntry?.isPending ?? false) === false,
        followupRequest,
        isPlanningMode: draftEntry?.isPlanningMode ?? false,
        isUltraMode: draftEntry?.isUltraMode ?? false,
        isSendingPrompt: draftEntry?.isPending ?? false,
        promptDraft: draftEntry?.value ?? "",
        queuedPrompts:
          scopedPromptDraftKey == null
            ? EMPTY_QUEUED_PROMPTS
            : (state.queuedPromptsByKey[scopedPromptDraftKey] ??
              EMPTY_QUEUED_PROMPTS),
        promptSettings: meta.promptSettings,
      };
    }),
  );

  return useMemo(
    () => ({
      ...draftState,
      setPlanningMode,
      setPromptDraft,
      setUltraMode,
    }),
    [draftState, setPlanningMode, setPromptDraft, setUltraMode],
  );
}
