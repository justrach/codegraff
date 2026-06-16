import { beforeEach, describe, expect, mock, test } from "bun:test";

import type {
  PromptSettings,
  RuntimeStatus,
  SessionSnapshot,
} from "../services/desktop/types/contracts";

let runtimeStatusCallCount = 0;
let promptSettingsCallCount = 0;
let conversationViewCallCount = 0;
let runtimeStatusImpl: (workspacePath: string | null) => Promise<RuntimeStatus | null>;
let promptSettingsImpl: (
  workspacePath: string | null,
) => Promise<PromptSettings | null>;
let conversationViewImpl: (
  workspacePath: string,
  conversationId: string,
) => Promise<SessionSnapshot>;

function deferred<T>() {
  let resolve!: (value: T) => void;

  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve;
  });

  return { promise, resolve };
}

const runtimeStatusFixture: RuntimeStatus = {
  availableOpenTargets: ["cursor"],
  configurationError: null,
  configured: true,
  gitBranchName: "main",
  gitBranches: ["main", "feature/zustand"],
  gitMainWorkspacePath: "/workspace/codegraff-gui",
  gitRepoName: "codegraff-gui",
  gitWorkspaceKind: "local",
  workspaceName: "Agent UI",
  workspacePath: "/workspace/codegraff-gui",
};

const promptSettingsFixture: PromptSettings = {
  availableModels: [],
  selectedModelId: "gpt-5.4",
  selectedProviderId: "openai",
  selectedReasoningEffort: "medium",
  fastEnabled: false,
};

function createSnapshot(
  overrides: Partial<SessionSnapshot> = {},
): SessionSnapshot {
  return {
    activeConversationId: "chat-1",
    activeWorkspacePath: "/workspace/codegraff-gui",
    conversationViews: [
      {
        activeRequestIds: [],
        conversationId: "chat-1",
        followup: null,
        messages: [],
        requestAgentIds: {},
        todos: [],
        workspacePath: "/workspace/codegraff-gui",
      },
    ],
    savedWorkspaces: [{ id: "saved-1", name: "Workspace", updatedAt: 1n }],
    uiError: null,
    visibleActiveRequestIds: [],
    visibleFollowup: null,
    visibleMessages: [],
    visibleRequestAgentIds: {},
    visibleTodos: [],
    workspaces: [
      {
        configurationError: null,
        configured: true,
        conversations: [
          {
            conversationId: "chat-1",
            hasPendingFollowup: false,
            isDraft: false,
            isRunning: false,
            title: "Chat 1",
            updatedAt: "2026-04-21T00:00:00.000Z",
          },
        ],
        kind: "project",
        selectedConversationId: "chat-1",
        workspaceName: "Agent UI",
        workspacePath: "/workspace/codegraff-gui",
      },
    ],
    ...overrides,
  };
}

mock.module("../services/desktop/client", () => ({
  setFast: async () => {},
  openExternalUrl: async () => {},
  openPathInTarget: async () => {},
  ensureConversationView: async (workspacePath: string, conversationId: string) => {
    conversationViewCallCount += 1;
    return await conversationViewImpl(workspacePath, conversationId);
  },
  getPromptSettings: async (workspacePath: string | null) => {
    promptSettingsCallCount += 1;
    return await promptSettingsImpl(workspacePath);
  },
  getRuntimeStatus: async (workspacePath: string | null) => {
    runtimeStatusCallCount += 1;
    return await runtimeStatusImpl(workspacePath);
  },
}));

const {
  ensureConversationViewLoaded,
  ensureWorkspacePromptSettingsLoaded,
  ensureWorkspaceRuntimeStatusLoaded,
  getAttachments,
  getPromptDraftState,
  getUiActiveConversationId,
  getUiActiveWorkspacePath,
  getWorkspaceMetaState,
  resetSessionStore,
  sessionStore,
} = await import("./sessionStore");

describe("sessionStore", () => {
  beforeEach(() => {
    conversationViewCallCount = 0;
    runtimeStatusCallCount = 0;
    promptSettingsCallCount = 0;
    conversationViewImpl = async () => createSnapshot();
    runtimeStatusImpl = async () => runtimeStatusFixture;
    promptSettingsImpl = async () => promptSettingsFixture;
    resetSessionStore();
  });

  test("applySessionSnapshot derives views, request agents, and request timings", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [],
        visibleActiveRequestIds: ["req-1"],
        visibleRequestAgentIds: { "req-1": "muse" },
      }),
    );

    const afterStart = sessionStore.getState();
    const startedView =
      afterStart.conversationViewsByKey["/workspace/codegraff-gui::chat-1"];
    const startedTiming =
      afterStart.requestTimingsByConversationId["chat-1"]?.["req-1"];

    expect(startedView?.activeRequestIds).toEqual(["req-1"]);
    expect(startedView?.requestAgentIds).toEqual({ "req-1": "muse" });
    expect(typeof startedTiming?.startedAtMs).toBe("number");
    expect(startedTiming?.completedAtMs).toBeNull();

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [],
        visibleActiveRequestIds: [],
      }),
    );

    const completedTiming =
      sessionStore.getState().requestTimingsByConversationId["chat-1"]?.["req-1"];
    expect(typeof completedTiming?.completedAtMs).toBe("number");
    expect((completedTiming?.completedAtMs ?? 0) >= startedTiming!.startedAtMs).toBe(
      true,
    );
  });

  test("applySessionSnapshot preserves saved workspace selection", () => {
    sessionStore.getState().setBoardSelection({
      activeChat: {
        conversationId: "chat-2",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "saved-workspace",
      workspace: {
        id: "saved-1",
        layoutJson: "{\"grid\":true}",
        name: "Workspace",
        updatedAt: 1n,
      },
    });

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: "chat-1",
      }),
    );

    expect(sessionStore.getState().selection).toEqual({
      activeChat: {
        conversationId: "chat-2",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "saved-workspace",
      workspace: {
        id: "saved-1",
        layoutJson: "{\"grid\":true}",
        name: "Workspace",
        updatedAt: 1n,
      },
    });
  });

  test("applySessionSnapshot refreshes saved workspace metadata", () => {
    sessionStore.getState().setBoardSelection({
      activeChat: {
        conversationId: "chat-2",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "saved-workspace",
      workspace: {
        id: "saved-1",
        layoutJson: "{\"grid\":true}",
        name: "Workspace",
        updatedAt: 1n,
      },
    });

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        savedWorkspaces: [{ id: "saved-1", name: "Renamed workspace", updatedAt: 2n }],
      }),
    );

    expect(sessionStore.getState().selection).toEqual({
      activeChat: {
        conversationId: "chat-2",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "saved-workspace",
      workspace: {
        id: "saved-1",
        layoutJson: "{\"grid\":true}",
        name: "Renamed workspace",
        updatedAt: 2n,
      },
    });
  });

  test("prompt drafts move and clear without leaving stale entries", () => {
    const sourceKey = "/workspace/codegraff-gui::chat-1";
    const destinationKey = "/workspace/codegraff-gui::chat-2";

    sessionStore.getState().setPromptDraftValue(sourceKey, "ship it");
    sessionStore.getState().setPromptDraftPlanningMode(sourceKey, true);
    sessionStore.getState().movePromptDraft(sourceKey, destinationKey);

    expect(getPromptDraftState(sourceKey)).toEqual({
      isPending: false,
      isPlanningMode: false,
      value: "",
    });
    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: true,
      value: "ship it",
    });

    sessionStore.getState().clearPromptDraft(destinationKey);

    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: true,
      value: "",
    });

    sessionStore.getState().setPromptDraftPlanningMode(destinationKey, false);

    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: false,
      value: "",
    });
    expect(sessionStore.getState().promptDraftsByKey[destinationKey]).toBeUndefined();
  });

  test("attachments move from the workspace draft key to the conversation key without being lost", () => {
    const sourceKey = "workspace:/workspace/codegraff-gui";
    const destinationKey = "conversation:chat-1";
    const attachment = {
      id: "/abs/report.pdf",
      path: "/abs/report.pdf",
      name: "report.pdf",
      ext: "pdf",
      kind: "pdf" as const,
    };

    // A file dropped in a new chat is keyed by the workspace draft key.
    sessionStore.getState().addAttachments(sourceKey, [attachment]);
    expect(getAttachments(sourceKey)).toEqual([attachment]);

    // When the first message creates a conversation, attachments must follow
    // the text draft to the new conversation key rather than being stranded.
    sessionStore.getState().moveAttachments(sourceKey, destinationKey);

    expect(getAttachments(sourceKey)).toEqual([]);
    expect(getAttachments(destinationKey)).toEqual([attachment]);
    expect(sessionStore.getState().attachmentsByKey[sourceKey]).toBeUndefined();

    sessionStore.getState().clearAttachments(destinationKey);
    expect(getAttachments(destinationKey)).toEqual([]);
    expect(
      sessionStore.getState().attachmentsByKey[destinationKey],
    ).toBeUndefined();
  });

  test("workspace draft selection ignores a stale active conversation", () => {
    sessionStore.getState().applySessionSnapshot(createSnapshot());
    sessionStore.getState().setBoardSelection({
      kind: "workspace-draft",
      workspacePath: "/workspace/other",
    });

    expect(getUiActiveWorkspacePath()).toBe("/workspace/other");
    expect(getUiActiveConversationId()).toBeNull();
  });

  test("workspace meta loaders dedupe concurrent runtime requests and cache prompt settings", async () => {
    const pendingRuntimeStatus = deferred<RuntimeStatus | null>();
    runtimeStatusImpl = async () => pendingRuntimeStatus.promise;

    const runtimeStatusRequestA = ensureWorkspaceRuntimeStatusLoaded(
      "/workspace/codegraff-gui",
    );
    const runtimeStatusRequestB = ensureWorkspaceRuntimeStatusLoaded(
      "/workspace/codegraff-gui",
    );

    expect(runtimeStatusCallCount).toBe(1);

    pendingRuntimeStatus.resolve(runtimeStatusFixture);

    expect(await runtimeStatusRequestA).toEqual(runtimeStatusFixture);
    expect(await runtimeStatusRequestB).toEqual(runtimeStatusFixture);
    expect(getWorkspaceMetaState("/workspace/codegraff-gui").runtimeStatusLoaded).toBe(
      true,
    );

    await ensureWorkspacePromptSettingsLoaded("/workspace/codegraff-gui");
    await ensureWorkspacePromptSettingsLoaded("/workspace/codegraff-gui");

    expect(promptSettingsCallCount).toBe(1);
    expect(
      getWorkspaceMetaState("/workspace/codegraff-gui").promptSettings,
    ).toEqual(promptSettingsFixture);
  });

  test("conversation view loader dedupes concurrent requests", async () => {
    const pendingConversationView = deferred<SessionSnapshot>();
    conversationViewImpl = async () => pendingConversationView.promise;

    const binding = {
      conversationId: "chat-2",
      workspacePath: "/workspace/codegraff-gui",
    };

    const requestA = ensureConversationViewLoaded(binding);
    const requestB = ensureConversationViewLoaded(binding);

    expect(conversationViewCallCount).toBe(1);

    pendingConversationView.resolve(
      createSnapshot({
        activeConversationId: "chat-2",
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-2",
            followup: null,
            messages: [],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
        visibleActiveRequestIds: [],
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [
              {
                conversationId: "chat-2",
                hasPendingFollowup: false,
                isDraft: false,
                isRunning: false,
                title: "Chat 2",
                updatedAt: "2026-04-21T00:00:00.000Z",
              },
            ],
            kind: "project",
            selectedConversationId: "chat-2",
            workspaceName: "Agent UI",
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    expect(await requestA).toEqual({
      activeRequestIds: [],
      conversationId: "chat-2",
      followup: null,
      messages: [],
      requestAgentIds: {},
      todos: [],
      workspacePath: "/workspace/codegraff-gui",
    });
    expect(await requestB).toEqual({
      activeRequestIds: [],
      conversationId: "chat-2",
      followup: null,
      messages: [],
      requestAgentIds: {},
      todos: [],
      workspacePath: "/workspace/codegraff-gui",
    });
  });
});
