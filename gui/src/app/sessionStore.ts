import { createStore } from "zustand/vanilla";

import type { Attachment } from "@/components/attachments/attachmentTypes";
import * as desktopClient from "../services/desktop/client";
import type {
  ChatBinding,
  ConversationViewSnapshot,
  PromptSettings,
  RuntimeStatus,
} from "../services/desktop/types/contracts";
import {
  defaultWorkspaceMetaState,
  getConversationStoreKeyForBinding,
  getWorkspaceMetaStoreKey,
} from "./sessionStoreHelpers";
import { createSessionStoreState } from "./sessionStoreState";
import type { SessionStoreState } from "./types/sessionStore";

export {
  areChatBindingsEqual,
  areSelectionsEqual,
  getConversationStoreKey,
  getConversationStoreKeyForBinding,
  getSelectionFromSnapshot,
  getWorkspaceMetaStoreKey,
} from "./sessionStoreHelpers";

export const sessionStore = createStore<SessionStoreState>((set) =>
  createSessionStoreState(set),
);

const runtimeStatusRequests = new Map<string, Promise<RuntimeStatus | null>>();
const conversationViewRequests = new Map<
  string,
  Promise<ConversationViewSnapshot | null>
>();
const promptSettingsRequests = new Map<
  string,
  Promise<PromptSettings | null>
>();
let latestConversationSelectionRequestId = 0;

export function resetSessionStore() {
  conversationViewRequests.clear();
  runtimeStatusRequests.clear();
  promptSettingsRequests.clear();
  latestConversationSelectionRequestId = 0;
  sessionStore.setState(createSessionStoreState(sessionStore.setState), true);
}

export function beginConversationSelectionRequest() {
  latestConversationSelectionRequestId += 1;
  return latestConversationSelectionRequestId;
}

export function isLatestConversationSelectionRequest(requestId: number) {
  return latestConversationSelectionRequestId === requestId;
}

export function getWorkspaceMetaState(workspacePath: string | null) {
  return (
    sessionStore.getState().workspaceMetaByKey[
      getWorkspaceMetaStoreKey(workspacePath)
    ] ?? defaultWorkspaceMetaState
  );
}

export function getWorkspaceSession(workspacePath: string) {
  return sessionStore.getState().workspacesByPath[workspacePath] ?? null;
}

export function getConversationSummary(binding: ChatBinding) {
  return (
    sessionStore.getState().conversationSummariesByKey[
      getConversationStoreKeyForBinding(binding)
    ] ?? null
  );
}

export function getConversationView(binding: ChatBinding) {
  return (
    sessionStore.getState().conversationViewsByKey[
      getConversationStoreKeyForBinding(binding)
    ] ?? null
  );
}

export function getPromptDraftState(promptDraftKey: string | null) {
  if (promptDraftKey == null) {
    return {
      isPending: false,
      isPlanningMode: false,
      isUltraMode: false,
      value: "",
    };
  }

  return (
    sessionStore.getState().promptDraftsByKey[promptDraftKey] ?? {
      isPending: false,
      isPlanningMode: false,
      isUltraMode: false,
      value: "",
    }
  );
}

const EMPTY_ATTACHMENTS: Attachment[] = [];

export function getAttachments(key: string | null) {
  if (key == null) {
    return EMPTY_ATTACHMENTS;
  }

  return sessionStore.getState().attachmentsByKey[key] ?? EMPTY_ATTACHMENTS;
}

export function getUiActiveBinding(
  state: Pick<
    SessionStoreState,
    "activeConversationId" | "activeWorkspacePath" | "selection"
  > = sessionStore.getState(),
): ChatBinding | null {
  switch (state.selection.kind) {
    case "saved-workspace":
      return state.selection.activeChat;
    case "single-chat":
      return state.selection.chat;
    default:
      if (
        state.activeWorkspacePath != null &&
        state.activeConversationId != null
      ) {
        return {
          workspacePath: state.activeWorkspacePath,
          conversationId: state.activeConversationId,
        };
      }

      return null;
  }
}

export function getUiActiveWorkspacePath(
  state: Pick<
    SessionStoreState,
    "activeWorkspacePath" | "selection"
  > = sessionStore.getState(),
): string | null {
  switch (state.selection.kind) {
    case "saved-workspace":
      return (
        state.selection.activeChat?.workspacePath ?? state.activeWorkspacePath
      );
    case "single-chat":
      return state.selection.chat.workspacePath;
    case "workspace-draft":
      return state.selection.workspacePath;
    case "empty":
      return state.activeWorkspacePath;
  }
}

export function getUiActiveConversationId(
  state: Pick<
    SessionStoreState,
    "activeConversationId" | "selection"
  > = sessionStore.getState(),
): string | null {
  switch (state.selection.kind) {
    case "saved-workspace":
      return state.selection.activeChat?.conversationId ?? null;
    case "single-chat":
      return state.selection.chat.conversationId;
    case "workspace-draft":
      return null;
    default:
      return state.activeConversationId;
  }
}

export function getUiWorkspaceLabel(
  workspacePath: string | null,
  runtimeStatus: RuntimeStatus | null,
): string {
  if (workspacePath != null) {
    return (
      sessionStore.getState().workspacesByPath[workspacePath]?.workspaceName ??
      runtimeStatus?.workspaceName ??
      "Projects"
    );
  }

  return runtimeStatus?.workspaceName ?? "Projects";
}

export async function ensureConversationViewLoaded(binding: ChatBinding) {
  const conversationKey = getConversationStoreKeyForBinding(binding);
  const existingView = getConversationView(binding);
  if (existingView != null) {
    return existingView;
  }

  const existingRequest = conversationViewRequests.get(conversationKey);
  if (existingRequest != null) {
    return existingRequest;
  }

  const request = (async () => {
    try {
      const snapshot = await desktopClient.ensureConversationView(
        binding.workspacePath,
        binding.conversationId,
      );
      sessionStore.getState().applySessionSnapshot(snapshot);
      return getConversationView(binding);
    } catch {
      return null;
    } finally {
      conversationViewRequests.delete(conversationKey);
    }
  })();

  conversationViewRequests.set(conversationKey, request);
  return await request;
}

export async function ensureWorkspaceRuntimeStatusLoaded(
  workspacePath: string | null,
  options?: { force?: boolean },
) {
  const workspaceMetaKey = getWorkspaceMetaStoreKey(workspacePath);
  const currentMeta = getWorkspaceMetaState(workspacePath);
  if (!options?.force && currentMeta.runtimeStatusLoaded) {
    return currentMeta.runtimeStatus;
  }

  const existingRequest = runtimeStatusRequests.get(workspaceMetaKey);
  if (existingRequest != null) {
    return existingRequest;
  }

  const request = (async () => {
    try {
      const runtimeStatus = await desktopClient.getRuntimeStatus(workspacePath);
      sessionStore
        .getState()
        .setWorkspaceRuntimeStatus(workspacePath, runtimeStatus);
      return runtimeStatus;
    } catch {
      sessionStore.getState().setWorkspaceRuntimeStatus(workspacePath, null);
      return null;
    } finally {
      runtimeStatusRequests.delete(workspaceMetaKey);
    }
  })();

  runtimeStatusRequests.set(workspaceMetaKey, request);
  return await request;
}

export async function ensureWorkspacePromptSettingsLoaded(
  workspacePath: string | null,
  options?: { force?: boolean },
) {
  const workspaceMetaKey = getWorkspaceMetaStoreKey(workspacePath);
  const currentMeta = getWorkspaceMetaState(workspacePath);
  if (!options?.force && currentMeta.promptSettingsLoaded) {
    return currentMeta.promptSettings;
  }

  const existingRequest = promptSettingsRequests.get(workspaceMetaKey);
  if (existingRequest != null) {
    return existingRequest;
  }

  const request = (async () => {
    try {
      const promptSettings =
        await desktopClient.getPromptSettings(workspacePath);
      sessionStore
        .getState()
        .setWorkspacePromptSettings(workspacePath, promptSettings);
      try {
        const runtimeStatus =
          await desktopClient.getRuntimeStatus(workspacePath);
        sessionStore
          .getState()
          .setWorkspaceRuntimeStatus(workspacePath, runtimeStatus);
      } catch {
        sessionStore.getState().setWorkspaceRuntimeStatus(workspacePath, null);
      }
      return promptSettings;
    } catch {
      sessionStore.getState().setWorkspacePromptSettings(workspacePath, null);
      return null;
    } finally {
      promptSettingsRequests.delete(workspaceMetaKey);
    }
  })();

  promptSettingsRequests.set(workspaceMetaKey, request);
  return await request;
}
