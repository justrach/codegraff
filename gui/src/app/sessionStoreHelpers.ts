import type {
  ChatBinding,
  ConversationSessionSummary,
  ConversationViewSnapshot,
  SessionSnapshot,
  WorkspaceSession,
} from "../services/desktop/types/contracts";
import type { WorkspaceBoardSelection } from "./types/sessionContext";
import type {
  PromptDraftEntry,
  SessionStoreState,
  WorkspaceMetaState,
} from "./types/sessionStore";

const GLOBAL_WORKSPACE_META_KEY = "__global__";

export function getConversationStoreKey(
  workspacePath: string,
  conversationId: string,
): string {
  return `${workspacePath}::${conversationId}`;
}

export function getConversationStoreKeyForBinding(binding: ChatBinding): string {
  return getConversationStoreKey(binding.workspacePath, binding.conversationId);
}

export function getWorkspaceMetaStoreKey(workspacePath: string | null): string {
  return workspacePath ?? GLOBAL_WORKSPACE_META_KEY;
}

export function areChatBindingsEqual(
  left: ChatBinding | null,
  right: ChatBinding | null,
): boolean {
  if (left === right) {
    return true;
  }

  if (left == null || right == null) {
    return false;
  }

  return (
    left.workspacePath === right.workspacePath &&
    left.conversationId === right.conversationId
  );
}

function getConversationDraftEntry(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
): PromptDraftEntry | null {
  return drafts[key] ?? null;
}

function writePromptDraftEntry(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
  entry: PromptDraftEntry | null,
): Record<string, PromptDraftEntry> {
  const current = drafts[key] ?? null;
  const nextEntry =
    entry == null ||
    (entry.value === "" &&
      !entry.isPending &&
      !entry.isPlanningMode &&
      !entry.isUltraMode)
      ? null
      : entry;

  if (nextEntry == null) {
    if (current == null) {
      return drafts;
    }

    const nextDrafts = { ...drafts };
    delete nextDrafts[key];
    return nextDrafts;
  }

  if (
    current?.value === nextEntry.value &&
    current?.isPending === nextEntry.isPending &&
    current?.isPlanningMode === nextEntry.isPlanningMode &&
    current?.isUltraMode === nextEntry.isUltraMode
  ) {
    return drafts;
  }

  return {
    ...drafts,
    [key]: nextEntry,
  };
}

export function setPromptDraftEntryValue(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
  value: string,
): Record<string, PromptDraftEntry> {
  const current = getConversationDraftEntry(drafts, key) ?? {
    isPending: false,
    isPlanningMode: false,
    isUltraMode: false,
    value: "",
  };

  return writePromptDraftEntry(drafts, key, { ...current, value });
}

export function setPromptDraftEntryPending(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
  isPending: boolean,
): Record<string, PromptDraftEntry> {
  const current = getConversationDraftEntry(drafts, key) ?? {
    isPending: false,
    isPlanningMode: false,
    isUltraMode: false,
    value: "",
  };

  return writePromptDraftEntry(drafts, key, { ...current, isPending });
}

export function setPromptDraftEntryPlanningMode(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
  isPlanningMode: boolean,
): Record<string, PromptDraftEntry> {
  const current = getConversationDraftEntry(drafts, key) ?? {
    isPending: false,
    isPlanningMode: false,
    isUltraMode: false,
    value: "",
  };

  return writePromptDraftEntry(drafts, key, { ...current, isPlanningMode });
}

export function setPromptDraftEntryUltraMode(
  drafts: Record<string, PromptDraftEntry>,
  key: string,
  isUltraMode: boolean,
): Record<string, PromptDraftEntry> {
  const current = getConversationDraftEntry(drafts, key) ?? {
    isPending: false,
    isPlanningMode: false,
    isUltraMode: false,
    value: "",
  };

  return writePromptDraftEntry(drafts, key, { ...current, isUltraMode });
}

export function movePromptDraftEntry(
  drafts: Record<string, PromptDraftEntry>,
  fromKey: string | null,
  toKey: string | null,
): Record<string, PromptDraftEntry> {
  if (fromKey == null || toKey == null || fromKey === toKey) {
    return drafts;
  }

  const draft = getConversationDraftEntry(drafts, fromKey);
  if (draft == null) {
    return drafts;
  }

  const nextDrafts = {
    ...writePromptDraftEntry(drafts, toKey, draft),
  };
  delete nextDrafts[fromKey];
  return nextDrafts;
}

export function getSelectionFromSnapshot(
  snapshot: SessionSnapshot,
): WorkspaceBoardSelection {
  if (
    snapshot.activeWorkspacePath != null &&
    snapshot.activeConversationId != null
  ) {
    return {
      kind: "single-chat",
      chat: {
        workspacePath: snapshot.activeWorkspacePath,
        conversationId: snapshot.activeConversationId,
      },
    };
  }

  if (snapshot.activeWorkspacePath != null) {
    return {
      kind: "workspace-draft",
      workspacePath: snapshot.activeWorkspacePath,
    };
  }

  return { kind: "empty" };
}

export function deriveConversationViews(snapshot: SessionSnapshot) {
  if (snapshot.conversationViews.length > 0) {
    return snapshot.conversationViews;
  }

  if (
    snapshot.activeWorkspacePath != null &&
    snapshot.activeConversationId != null
  ) {
    return [
      {
        activeRequestIds: snapshot.visibleActiveRequestIds,
        conversationId: snapshot.activeConversationId,
        followup: snapshot.visibleFollowup,
        messages: snapshot.visibleMessages,
        requestAgentIds: snapshot.visibleRequestAgentIds,
        todos: snapshot.visibleTodos,
        workspacePath: snapshot.activeWorkspacePath,
      } satisfies ConversationViewSnapshot,
    ];
  }

  return [];
}

export function buildWorkspacesByPath(workspaces: WorkspaceSession[]) {
  const byPath: Record<string, WorkspaceSession> = {};
  for (const workspace of workspaces) {
    byPath[workspace.workspacePath] = workspace;
  }
  return byPath;
}

export function buildConversationSummariesByKey(
  workspaces: WorkspaceSession[],
) {
  const byKey: Record<string, ConversationSessionSummary> = {};

  for (const workspace of workspaces) {
    for (const conversation of workspace.conversations) {
      byKey[
        getConversationStoreKey(
          workspace.workspacePath,
          conversation.conversationId,
        )
      ] = conversation;
    }
  }

  return byKey;
}

export function areSelectionsEqual(
  left: WorkspaceBoardSelection,
  right: WorkspaceBoardSelection,
): boolean {
  if (left === right) {
    return true;
  }

  if (left.kind !== right.kind) {
    return false;
  }

  switch (left.kind) {
    case "empty":
      return true;
    case "single-chat": {
      const rightSelection = right as Extract<
        WorkspaceBoardSelection,
        { kind: "single-chat" }
      >;
      return areChatBindingsEqual(left.chat, rightSelection.chat);
    }
    case "workspace-draft": {
      const rightSelection = right as Extract<
        WorkspaceBoardSelection,
        { kind: "workspace-draft" }
      >;
      return left.workspacePath === rightSelection.workspacePath;
    }
    case "saved-workspace": {
      const rightSelection = right as Extract<
        WorkspaceBoardSelection,
        { kind: "saved-workspace" }
      >;
      return (
        left.workspace.id === rightSelection.workspace.id &&
        left.workspace.layoutJson === rightSelection.workspace.layoutJson &&
        left.workspace.name === rightSelection.workspace.name &&
        left.workspace.updatedAt === rightSelection.workspace.updatedAt &&
        areChatBindingsEqual(left.activeChat, rightSelection.activeChat)
      );
    }
  }
}

export const defaultWorkspaceMetaState: WorkspaceMetaState = {
  promptSettings: null,
  promptSettingsLoaded: false,
  runtimeStatus: null,
  runtimeStatusLoaded: false,
};

export function setWorkspaceMetaState(
  currentState: SessionStoreState,
  workspacePath: string | null,
  updater: (currentMeta: WorkspaceMetaState) => WorkspaceMetaState,
) {
  const workspaceMetaKey = getWorkspaceMetaStoreKey(workspacePath);
  const currentMeta =
    currentState.workspaceMetaByKey[workspaceMetaKey] ??
    defaultWorkspaceMetaState;
  const nextMeta = updater(currentMeta);

  if (
    nextMeta.promptSettings === currentMeta.promptSettings &&
    nextMeta.promptSettingsLoaded === currentMeta.promptSettingsLoaded &&
    nextMeta.runtimeStatus === currentMeta.runtimeStatus &&
    nextMeta.runtimeStatusLoaded === currentMeta.runtimeStatusLoaded
  ) {
    return currentState.workspaceMetaByKey;
  }

  return {
    ...currentState.workspaceMetaByKey,
    [workspaceMetaKey]: nextMeta,
  };
}
