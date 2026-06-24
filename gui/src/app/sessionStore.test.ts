import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

import type {
  PromptSettings,
  RuntimeStatus,
  SessionMessage,
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
  availableOpenTargets: ["file-manager"],
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
  fastApplies: false,
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
    savedWorkspaces: [{ id: "saved-1", name: "Workspace", updatedAt: 1 }],
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
  saveAttachmentFile: async (input: { name: string }) => `/tmp/${input.name}`,
  savePastedImage: async () => "/tmp/pasted-image.png",
  readClipboardText: async () => "",
  writeClipboardText: async () => {},
  pickDirectory: async () => "/workspace/codegraff-gui",
  drainPendingOpen: async () => null,
  imageThumbnail: async () => "data:image/jpeg;base64,",
  openExternalUrl: async () => {},
  openInTarget: async () => {},
  openPathDefault: async () => {},
  openPathForEdit: async () => {},
  openPathInTarget: async () => {},
  setWindowTitle: async () => {},
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

afterAll(() => {
  mock.restore();
});

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

  test("applySessionSnapshot preserves pending optimistic in-chat submits across stale snapshots", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-old",
                kind: "user",
                requestId: "req-old",
                text: "previous",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "new prompt",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-old",
                kind: "user",
                requestId: "req-old",
                text: "previous",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-1"
    ];
    expect(view?.messages.map((message) => message.id)).toEqual([
      "user-old",
      "optimistic-1-user",
    ]);
    expect(view?.activeRequestIds).toContain("optimistic-1");
  });

  test("applySessionSnapshot preserves optimistic in-chat selection when stale native snapshot omits the view", () => {
    sessionStore.getState().applySessionSnapshot(createSnapshot());
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "native enter",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
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

    expect(getUiActiveConversationId()).toBe("chat-1");
    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-1"
    ];
    expect(view?.messages.map((message) => message.id)).toContain(
      "optimistic-1-user",
    );
  });

  test("applySessionSnapshot preserves optimistic new-chat selection across stale native workspace snapshots", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: null,
        conversationViews: [],
        visibleMessages: [],
      }),
    );
    sessionStore.getState().appendOptimisticUserMessage(
      {
        conversationId: "optimistic-chat-1",
        workspacePath: "/workspace/codegraff-gui",
      },
      "optimistic-1",
      "first native prompt",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: null,
        conversationViews: [],
        visibleMessages: [],
      }),
    );

    expect(getUiActiveConversationId()).toBe("optimistic-chat-1");
    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::optimistic-chat-1"
    ];
    expect(view?.messages.map((message) => message.id)).toEqual([
      "optimistic-1-user",
    ]);
  });

  test("applySessionSnapshot does not treat stale same-text active chats as accepted optimistic submits", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: "chat-2",
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-2",
            followup: null,
            messages: [
              {
                id: "req-old-user",
                kind: "user",
                requestId: "req-old",
                text: "continue",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
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
    sessionStore.getState().setBoardSelection({
      kind: "single-chat",
      chat: { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
    });
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "continue",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: "chat-2",
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-2",
            followup: null,
            messages: [
              {
                id: "req-old-user",
                kind: "user",
                requestId: "req-old",
                text: "continue",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    expect(getUiActiveConversationId()).toBe("chat-1");
  });

  test("applySessionSnapshot keeps optimistic new-chat selection until submit command syncs accepted snapshot", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: null,
        conversationViews: [],
        visibleMessages: [],
      }),
    );
    sessionStore.getState().appendOptimisticUserMessage(
      {
        conversationId: "optimistic-chat-1",
        workspacePath: "/workspace/codegraff-gui",
      },
      "optimistic-1",
      "first native prompt",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        activeConversationId: "chat-real",
        conversationViews: [
          {
            activeRequestIds: ["req-real"],
            conversationId: "chat-real",
            followup: null,
            messages: [
              {
                id: "req-real-user",
                kind: "user",
                requestId: "req-real",
                text: "first native prompt",
              },
            ],
            requestAgentIds: { "req-real": "forge" },
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    expect(getUiActiveConversationId()).toBe("optimistic-chat-1");
    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-real"
    ];
    expect(view?.messages.map((message) => message.id)).toEqual([
      "req-real-user",
    ]);

    sessionStore.getState().setBoardSelection({
      kind: "single-chat",
      chat: { conversationId: "chat-real", workspacePath: "/workspace/codegraff-gui" },
    });
    expect(getUiActiveConversationId()).toBe("chat-real");
  });

  test("applySessionSnapshot preserves optimistic submit when stale snapshot grows with old same-text turn", () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-old",
                kind: "user",
                requestId: "req-old",
                text: "retry",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "retry",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-old",
                kind: "user",
                requestId: "req-old",
                text: "retry",
              },
              {
                id: "assistant-old",
                kind: "assistant",
                requestId: "req-old",
                text: "done",
              },
            ],
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-1"
    ];
    expect(view?.messages.map((message) => message.id)).toEqual([
      "user-old",
      "assistant-old",
      "optimistic-1-user",
    ]);
  });

  test("applySessionSnapshot replaces optimistic submits with accepted completed backend messages", () => {
    sessionStore.getState().applySessionSnapshot(createSnapshot());
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "quick response",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-real",
                kind: "user",
                requestId: "req-real",
                text: "quick response",
              },
              {
                id: "assistant-real",
                kind: "assistant",
                requestId: "req-real",
                text: "done",
              },
            ],
            requestAgentIds: { "req-real": "forge" },
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-1"
    ];
    expect(view?.messages.map((message) => message.id)).toEqual([
      "user-real",
      "assistant-real",
    ]);
    expect(view?.activeRequestIds).toEqual([]);
  });

  test("applySessionSnapshot replaces optimistic submits with accepted backend messages", () => {
    sessionStore.getState().applySessionSnapshot(createSnapshot());
    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "new prompt",
      "forge",
    );

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: ["req-real"],
            conversationId: "chat-1",
            followup: null,
            messages: [
              {
                id: "user-real",
                kind: "user",
                requestId: "req-real",
                text: "new prompt",
              },
            ],
            requestAgentIds: { "req-real": "forge" },
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    const view = sessionStore.getState().conversationViewsByKey[
      "/workspace/codegraff-gui::chat-1"
    ];
    expect(view?.messages).toEqual([
      {
        id: "user-real",
        kind: "user",
        requestId: "req-real",
        text: "new prompt",
      },
    ]);
    expect(view?.activeRequestIds).toEqual(["req-real"]);
  });

  test("appendOptimisticUserMessage preserves saved workspace selection for active panel chat", () => {
    const savedSelection = {
      activeChat: {
        conversationId: "chat-1",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "saved-workspace" as const,
      workspace: {
        id: "saved-1",
        layoutJson: "{\"grid\":true}",
        name: "Workspace",
        updatedAt: 1,
      },
    };
    sessionStore.getState().setBoardSelection(savedSelection);

    sessionStore.getState().appendOptimisticUserMessage(
      { conversationId: "chat-1", workspacePath: "/workspace/codegraff-gui" },
      "optimistic-1",
      "panel prompt",
      "forge",
    );

    expect(sessionStore.getState().selection).toEqual(savedSelection);
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
        updatedAt: 1,
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
        updatedAt: 1,
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
        updatedAt: 1,
      },
    });

    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        savedWorkspaces: [{ id: "saved-1", name: "Renamed workspace", updatedAt: 2 }],
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
        updatedAt: 2,
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
      isUltraMode: false,
      value: "",
    });
    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: true,
      isUltraMode: false,
      value: "ship it",
    });

    sessionStore.getState().clearPromptDraft(destinationKey);

    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: true,
      isUltraMode: false,
      value: "",
    });

    sessionStore.getState().setPromptDraftPlanningMode(destinationKey, false);

    expect(getPromptDraftState(destinationKey)).toEqual({
      isPending: false,
      isPlanningMode: false,
      isUltraMode: false,
      value: "",
    });
    expect(sessionStore.getState().promptDraftsByKey[destinationKey]).toBeUndefined();
  });

  test("toggling Ultra mode persists even when the draft is otherwise unchanged", () => {
    // Regression: writePromptDraftEntry's no-change guard previously omitted
    // isUltraMode, so flipping Ultra while value/pending/planning stayed the same
    // was discarded as a no-op — the composer's `cg-ultra-shine` never engaged.
    const key = "/workspace/codegraff-gui::ultra-regression";

    // A draft entry already exists (the user has typed) — the exact showcase
    // scenario where the dropped update bit.
    sessionStore.getState().setPromptDraftValue(key, "describe the job");

    sessionStore.getState().setPromptDraftUltraMode(key, true);
    expect(getPromptDraftState(key)).toEqual({
      isPending: false,
      isPlanningMode: false,
      isUltraMode: true,
      value: "describe the job",
    });

    // Toggling back off must also stick.
    sessionStore.getState().setPromptDraftUltraMode(key, false);
    expect(getPromptDraftState(key).isUltraMode).toBe(false);

    // Ultra composes independently with planning mode.
    sessionStore.getState().setPromptDraftPlanningMode(key, true);
    sessionStore.getState().setPromptDraftUltraMode(key, true);
    expect(getPromptDraftState(key)).toEqual({
      isPending: false,
      isPlanningMode: true,
      isUltraMode: true,
      value: "describe the job",
    });
  });

  test("queued prompts move from optimistic new-chat key to materialized conversation key", () => {
    const sourceKey = "conversation:optimistic-chat-1";
    const destinationKey = "conversation:chat-real";
    const queued = {
      attachments: [],
      isPlanningMode: false,
      isUltraMode: true,
      value: "follow up",
    };

    sessionStore.getState().enqueuePrompt(sourceKey, queued);
    sessionStore.getState().moveQueuedPrompts(sourceKey, destinationKey);

    expect(sessionStore.getState().queuedPromptsByKey[sourceKey]).toBeUndefined();
    expect(sessionStore.getState().queuedPromptsByKey[destinationKey]).toEqual([
      queued,
    ]);
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

  test("message deltas maintain per-conversation message indices and versions", () => {
    const historicalMessages: SessionMessage[] = Array.from(
      { length: 250 },
      (_value, index) => ({
        id: `assistant-old-${index}`,
        kind: "assistant" as const,
        requestId: `old-${index}`,
        text: `historical ${index}`,
      }),
    );
    sessionStore.getState().applySessionSnapshot(
      createSnapshot({
        conversationViews: [
          {
            activeRequestIds: ["req-stream"],
            conversationId: "chat-1",
            followup: null,
            messages: historicalMessages,
            requestAgentIds: {},
            todos: [],
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );

    const key = "/workspace/codegraff-gui::chat-1";
    const initialVersion = sessionStore.getState().conversationVersionsByKey[key] ?? 0;

    sessionStore.getState().appendMessageDelta({
      conversationId: "chat-1",
      kind: "assistant",
      messageId: "streaming-message",
      requestId: "req-stream",
      text: "hello",
      workspacePath: "/workspace/codegraff-gui",
    });
    for (let index = 0; index < 100; index += 1) {
      sessionStore.getState().appendMessageDelta({
        conversationId: "chat-1",
        kind: "assistant",
        messageId: "streaming-message",
        requestId: "req-stream",
        text: "!",
        workspacePath: "/workspace/codegraff-gui",
      });
    }

    const state = sessionStore.getState();
    const view = state.conversationViewsByKey[key];
    const messageIndex = state.conversationMessageIndicesByKey[key]?.[
      "streaming-message"
    ];
    expect(messageIndex).toBe(250);
    expect(view?.messages[messageIndex ?? -1]).toEqual({
      id: "streaming-message",
      kind: "assistant",
      requestId: "req-stream",
      text: `hello${"!".repeat(100)}`,
    });
    expect(state.conversationVersionsByKey[key]).toBe(initialVersion + 101);
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
