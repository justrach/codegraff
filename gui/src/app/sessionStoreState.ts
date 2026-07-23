import type {
  SessionStoreSetter,
  SessionStoreState,
} from "./types/sessionStore";
import {
  areSelectionsEqual,
  buildConversationSummariesByKey,
  buildWorkspacesByPath,
  deriveConversationViews,
  getConversationStoreKey,
  getSelectionFromSnapshot,
  movePromptDraftEntry,
  setPromptDraftEntryPending,
  setPromptDraftEntryPlanningMode,
  setPromptDraftEntryUltraMode,
  setPromptDraftEntryValue,
  setWorkspaceMetaState,
} from "./sessionStoreHelpers";

export function createSessionStoreState(
  set: SessionStoreSetter,
): SessionStoreState {
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
                (workspace) =>
                  workspace.id === savedWorkspaceSelection.workspace.id,
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
        areSelectionsEqual(current.selection, selection)
          ? current
          : { selection },
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
