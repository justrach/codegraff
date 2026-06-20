import { createStore } from "zustand/vanilla";

import * as desktopClient from "../services/desktop/client";
import type { Attachment } from "@/components/attachments/attachmentTypes";
import type {
  ChatBinding,
  ConversationSessionSummary,
  ConversationViewSnapshot,
  PromptSettings,
  RuntimeStatus,
  SessionSnapshot,
  WorkspaceSession,
} from "../services/desktop/types/contracts";
import type { WorkspaceBoardSelection } from "./types/sessionContext";
import type {
  PromptDraftEntry,
  SessionStoreSetter,
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
    current?.isPlanningMode === nextEntry.isPlanningMode &&
    current?.isUltraMode === nextEntry.isUltraMode
  if (
    current?.value === nextEntry.value &&
    current?.isPending === nextEntry.isPending &&
    current?.isPlanningMode === nextEntry.isPlanningMode
  ) {
    return drafts;
  }

  return {
    ...drafts,
    [key]: nextEntry,
  };
}

function setPromptDraftEntryValue(
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

function setPromptDraftEntryPending(
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

function setPromptDraftEntryPlanningMode(
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

function setPromptDraftEntryUltraMode(
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

function movePromptDraftEntry(
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

function deriveConversationViews(snapshot: SessionSnapshot) {
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

function buildWorkspacesByPath(workspaces: WorkspaceSession[]) {
  const byPath: Record<string, WorkspaceSession> = {};
  for (const workspace of workspaces) {
    byPath[workspace.workspacePath] = workspace;
  }
  return byPath;
}

function buildConversationSummariesByKey(workspaces: WorkspaceSession[]) {
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

function setWorkspaceMetaState(
  currentState: SessionStoreState,
  workspacePath: string | null,
  updater: (currentMeta: WorkspaceMetaState) => WorkspaceMetaState,
) {
  const workspaceMetaKey = getWorkspaceMetaStoreKey(workspacePath);
  const currentMeta =
    currentState.workspaceMetaByKey[workspaceMetaKey] ?? defaultWorkspaceMetaState;
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

const defaultWorkspaceMetaState: WorkspaceMetaState = {
  promptSettings: null,
  promptSettingsLoaded: false,
  runtimeStatus: null,
  runtimeStatusLoaded: false,
};

function createSessionStoreState(set: SessionStoreSetter): SessionStoreState {
  return {
    activeConversationId: null,
    activeWorkspacePath: null,
    attachmentsByKey: {},
    conversationSummariesByKey: {},
    conversationViewsByKey: {},
    isBootstrapped: false,
    isOpeningProject: false,
    promptDraftsByKey: {},
    requestTimingsByConversationId: {},
    savedWorkspaces: [],
    selection: { kind: "empty" },
    uiError: null,
    workspaceMetaByKey: {},
    workspaces: [],
    workspacesByPath: {},
    applySessionSnapshot: (snapshot) => {
      const nextViews = deriveConversationViews(snapshot);
      set((current) => {
        const now = Date.now();
        let nextRequestTimingsByConversationId =
          current.requestTimingsByConversationId;

        if (nextViews.length > 0) {
          let didChangeTimings = false;
          const nextTimingsState = {
            ...current.requestTimingsByConversationId,
          };

          for (const view of nextViews) {
            const currentConversationTimings =
              current.requestTimingsByConversationId[view.conversationId] ?? {};
            const nextConversationTimings = { ...currentConversationTimings };
            const activeRequestIdSet = new Set(view.activeRequestIds ?? []);

            for (const requestId of view.activeRequestIds ?? []) {
              if (nextConversationTimings[requestId] == null) {
                nextConversationTimings[requestId] = {
                  completedAtMs: null,
                  startedAtMs: now,
                };
                didChangeTimings = true;
              }
            }

            for (const [requestId, timing] of Object.entries(
              nextConversationTimings,
            )) {
              if (
                timing.completedAtMs == null &&
                !activeRequestIdSet.has(requestId)
              ) {
                nextConversationTimings[requestId] = {
                  ...timing,
                  completedAtMs: now,
                };
                didChangeTimings = true;
              }
            }

            nextTimingsState[view.conversationId] = nextConversationTimings;
          }

          if (didChangeTimings) {
            nextRequestTimingsByConversationId = nextTimingsState;
          }
        }

        const nextConversationViewsByKey = { ...current.conversationViewsByKey };
        for (const view of nextViews) {
          nextConversationViewsByKey[
            getConversationStoreKey(view.workspacePath, view.conversationId)
          ] = view;
        }

        return {
          activeConversationId: snapshot.activeConversationId,
          activeWorkspacePath: snapshot.activeWorkspacePath,
          conversationSummariesByKey: buildConversationSummariesByKey(
            snapshot.workspaces,
          ),
          conversationViewsByKey: nextConversationViewsByKey,
          requestTimingsByConversationId: nextRequestTimingsByConversationId,
          savedWorkspaces: snapshot.savedWorkspaces,
          selection: (() => {
            if (current.selection.kind === "saved-workspace") {
              const savedWorkspaceSelection = current.selection;
              const matchingSavedWorkspace = snapshot.savedWorkspaces.find(
                (workspace) => workspace.id === savedWorkspaceSelection.workspace.id,
              );
              return matchingSavedWorkspace == null
                ? getSelectionFromSnapshot(snapshot)
                : {
                    ...savedWorkspaceSelection,
                    workspace: {
                      ...savedWorkspaceSelection.workspace,
                      name: matchingSavedWorkspace.name,
                      updatedAt: matchingSavedWorkspace.updatedAt,
                    },
                  };
            }

            return getSelectionFromSnapshot(snapshot);
          })(),
          uiError: snapshot.uiError,
          workspaces: snapshot.workspaces,
          workspacesByPath: buildWorkspacesByPath(snapshot.workspaces),
        };
      });
    },
    addAttachments: (key, items) => {
      if (key == null || items.length === 0) {
        return;
      }

      set((current) => {
        const existing = current.attachmentsByKey[key] ?? [];
        const existingPaths = new Set(existing.map((item) => item.path));
        const additions = items.filter((item) => !existingPaths.has(item.path));
        if (additions.length === 0) {
          return current;
        }

        return {
          attachmentsByKey: {
            ...current.attachmentsByKey,
            [key]: [...existing, ...additions],
          },
        };
      });
    },
    removeAttachment: (key, id) => {
      if (key == null) {
        return;
      }

      set((current) => {
        const existing = current.attachmentsByKey[key];
        if (existing == null) {
          return current;
        }

        const next = existing.filter((item) => item.id !== id);
        const nextByKey = { ...current.attachmentsByKey };
        if (next.length === 0) {
          delete nextByKey[key];
        } else {
          nextByKey[key] = next;
        }

        return { attachmentsByKey: nextByKey };
      });
    },
    clearAttachments: (key) => {
      if (key == null) {
        return;
      }

      set((current) => {
        if (current.attachmentsByKey[key] == null) {
          return current;
        }

        const nextByKey = { ...current.attachmentsByKey };
        delete nextByKey[key];
        return { attachmentsByKey: nextByKey };
      });
    },
    clearPromptDraft: (key) => {
      if (key == null) {
        return;
      }

      set((current) => ({
        promptDraftsByKey: setPromptDraftEntryValue(
          current.promptDraftsByKey,
          key,
          "",
        ),
      }));
    },
    movePromptDraft: (fromKey, toKey) => {
      set((current) => ({
        promptDraftsByKey: movePromptDraftEntry(
          current.promptDraftsByKey,
          fromKey,
          toKey,
        ),
      }));
    },
    moveAttachments: (fromKey, toKey) => {
      if (fromKey == null || toKey == null || fromKey === toKey) {
        return;
      }

      set((current) => {
        const moving = current.attachmentsByKey[fromKey];
        if (moving == null) {
          return current;
        }

        const nextByKey = { ...current.attachmentsByKey };
        delete nextByKey[fromKey];

        const existing = nextByKey[toKey] ?? [];
        const existingPaths = new Set(existing.map((item) => item.path));
        nextByKey[toKey] = [
          ...existing,
          ...moving.filter((item) => !existingPaths.has(item.path)),
        ];

        return { attachmentsByKey: nextByKey };
      });
    },
    setBoardSelection: (selection) => {
      set((current) =>
        areSelectionsEqual(current.selection, selection) ? current : { selection },
      );
    },
    setIsBootstrapped: (value) => {
      set((current) =>
        current.isBootstrapped === value ? current : { isBootstrapped: value },
      );
    },
    setIsOpeningProject: (value) => {
      set((current) =>
        current.isOpeningProject === value
          ? current
          : { isOpeningProject: value },
      );
    },
    setPromptDraftPending: (key, isPending) => {
      if (key == null) {
        return;
      }

      set((current) => ({
        promptDraftsByKey: setPromptDraftEntryPending(
          current.promptDraftsByKey,
          key,
          isPending,
        ),
      }));
    },
    setPromptDraftPlanningMode: (key, isPlanningMode) => {
      if (key == null) {
        return;
      }

      set((current) => ({
        promptDraftsByKey: setPromptDraftEntryPlanningMode(
          current.promptDraftsByKey,
          key,
          isPlanningMode,
        ),
      }));
    },
    setPromptDraftUltraMode: (key, isUltraMode) => {
      if (key == null) {
        return;
      }

      set((current) => ({
        promptDraftsByKey: setPromptDraftEntryUltraMode(
          current.promptDraftsByKey,
          key,
          isUltraMode,
        ),
      }));
    },
    setPromptDraftValue: (key, value) => {
      if (key == null) {
        return;
      }

      set((current) => ({
        promptDraftsByKey: setPromptDraftEntryValue(
          current.promptDraftsByKey,
          key,
          value,
        ),
      }));
    },
    setWorkspacePromptSettings: (workspacePath, promptSettings) => {
      set((current) => ({
        workspaceMetaByKey: setWorkspaceMetaState(
          current,
          workspacePath,
          (currentMeta) => ({
            ...currentMeta,
            promptSettings,
            promptSettingsLoaded: true,
          }),
        ),
      }));
    },
    setWorkspaceRuntimeStatus: (workspacePath, runtimeStatus) => {
      set((current) => ({
        workspaceMetaByKey: setWorkspaceMetaState(
          current,
          workspacePath,
          (currentMeta) => ({
            ...currentMeta,
            runtimeStatus,
            runtimeStatusLoaded: true,
          }),
        ),
      }));
    },
  };
}

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
      return state.selection.activeChat?.workspacePath ?? state.activeWorkspacePath;
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
      const promptSettings = await desktopClient.getPromptSettings(workspacePath);
      sessionStore
        .getState()
        .setWorkspacePromptSettings(workspacePath, promptSettings);
      try {
        const runtimeStatus = await desktopClient.getRuntimeStatus(workspacePath);
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
