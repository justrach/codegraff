import { beforeEach, describe, expect, mock, test } from "bun:test";
import { useContext } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type {
  PromptSettings,
  RuntimeStatus,
  SessionSnapshot,
} from "../services/desktop/types/contracts";
import type { SessionActionsContextValue } from "./types/sessionContext";

let ensureConversationViewCallCount = 0;
let getPromptSettingsCallCount = 0;
let getRuntimeStatusCallCount = 0;
let createManagedChatCallCount = 0;
let handoffChatCallCount = 0;
let openWorkspaceCallCount = 0;
let renameWorkspaceCallCount = 0;
let renameSavedWorkspaceCallCount = 0;
let selectConversationCallCount = 0;
let stopPromptCallCount = 0;
let sendPromptCallCount = 0;
let lastSendPromptInput:
  | import("../services/desktop/types/contracts").SendPromptInput
  | null = null;
let sendPromptImpl: (
  input: import("../services/desktop/types/contracts").SendPromptInput,
) => Promise<SessionSnapshot>;
let createManagedChatImpl: () => Promise<SessionSnapshot>;
let handoffChatImpl: (
  input: import("../services/desktop/types/contracts").HandoffChatInput,
) => Promise<SessionSnapshot>;
let openWorkspaceImpl: (workspacePath: string) => Promise<SessionSnapshot>;
let renameWorkspaceImpl: (
  workspacePath: string,
  displayName: string | null,
) => Promise<SessionSnapshot>;
let renameSavedWorkspaceImpl: (
  workspaceId: string,
  name: string,
) => Promise<SessionSnapshot>;
let lastStopPromptInput:
  | import("../services/desktop/types/contracts").ChatBinding
  | null = null;

function deferred<T>() {
  let resolve!: (value: T) => void;

  const promise = new Promise<T>((nextResolve) => {
    resolve = nextResolve;
  });

  return { promise, resolve };
}

function createSnapshot(
  workspacePath: string,
  conversationId: string,
  overrides: Partial<SessionSnapshot> = {},
): SessionSnapshot {
  return {
    activeConversationId: conversationId,
    activeWorkspacePath: workspacePath,
    conversationViews: [
      {
        activeRequestIds: [],
        conversationId,
        followup: null,
        messages: [],
        requestAgentIds: {},
        todos: [],
        workspacePath,
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
            conversationId,
            hasPendingFollowup: false,
            isDraft: false,
            isRunning: false,
            title: "Selected chat",
            updatedAt: "2026-04-21T00:00:00.000Z",
          },
        ],
        kind: "project",
        selectedConversationId: conversationId,
        workspaceName: "Agent UI",
        workspacePath,
      },
    ],
    ...overrides,
  };
}

const runtimeStatusFixture: RuntimeStatus = {
  availableOpenTargets: ["cursor"],
  configurationError: null,
  configured: true,
  gitBranchName: "main",
  gitBranches: ["main"],
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

mock.module("../hooks/useSessionBootstrap", () => ({
  useSessionBootstrap: () => {},
}));

mock.module("../services/desktop/client", () => ({
  setFast: async () => {},
  savePastedImage: async () => "/tmp/pasted-image.png",
  imageThumbnail: async () => "data:image/jpeg;base64,",
  openExternalUrl: async () => {},
  openPathInTarget: async () => {},
  ensureConversationView: async () => {
    ensureConversationViewCallCount += 1;
    return createSnapshot("/workspace/unused", "unused");
  },
  getPromptSettings: async () => {
    getPromptSettingsCallCount += 1;
    return promptSettingsFixture;
  },
  getRuntimeStatus: async () => {
    getRuntimeStatusCallCount += 1;
    return runtimeStatusFixture;
  },
  renameWorkspace: async (workspacePath: string, displayName: string | null) => {
    renameWorkspaceCallCount += 1;
    return await renameWorkspaceImpl(workspacePath, displayName);
  },
  renameSavedWorkspace: async (workspaceId: string, name: string) => {
    renameSavedWorkspaceCallCount += 1;
    return await renameSavedWorkspaceImpl(workspaceId, name);
  },
  createManagedChat: async () => {
    createManagedChatCallCount += 1;
    return await createManagedChatImpl();
  },
  handoffChat: async (
    input: import("../services/desktop/types/contracts").HandoffChatInput,
  ) => {
    handoffChatCallCount += 1;
    return await handoffChatImpl(input);
  },
  openWorkspace: async (workspacePath: string) => {
    openWorkspaceCallCount += 1;
    return await openWorkspaceImpl(workspacePath);
  },
  selectConversation: async (workspacePath: string, conversationId: string) => {
    selectConversationCallCount += 1;
    return createSnapshot(workspacePath, conversationId);
  },
  sendPrompt: async (
    input: import("../services/desktop/types/contracts").SendPromptInput,
  ) => {
    sendPromptCallCount += 1;
    lastSendPromptInput = input;
    return await sendPromptImpl(input);
  },
  stopPrompt: async (
    input: import("../services/desktop/types/contracts").ChatBinding,
  ) => {
    stopPromptCallCount += 1;
    lastStopPromptInput = input;
  },
}));

const { SessionActionsContext } = await import("./SessionContext");
const { SessionProvider } = await import("./SessionProvider");
const { getPromptDraftKey } = await import("./sessionSnapshot");
const { resetSessionStore, sessionStore } = await import("./sessionStore");

describe("SessionProvider", () => {
  beforeEach(() => {
    ensureConversationViewCallCount = 0;
    getPromptSettingsCallCount = 0;
    getRuntimeStatusCallCount = 0;
    createManagedChatCallCount = 0;
    handoffChatCallCount = 0;
    openWorkspaceCallCount = 0;
    renameWorkspaceCallCount = 0;
    renameSavedWorkspaceCallCount = 0;
    selectConversationCallCount = 0;
    stopPromptCallCount = 0;
    sendPromptCallCount = 0;
    lastStopPromptInput = null;
    lastSendPromptInput = null;
    sendPromptImpl = async (input) =>
      createSnapshot(input.workspacePath, input.conversationId ?? "chat-1");
    createManagedChatImpl = async () =>
      createSnapshot("/workspace/managed-chat", "chat-1", {
        activeConversationId: null,
        conversationViews: [],
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [],
            kind: "managed_chat",
            selectedConversationId: null,
            workspaceName: "New chat",
            workspacePath: "/workspace/managed-chat",
          },
        ],
      });
    handoffChatImpl = async (input) =>
      createSnapshot(
        input.target === "worktree"
          ? "/workspace/codegraff-gui-worktree"
          : "/workspace/codegraff-gui",
        input.conversationId ?? "chat-1",
        {
          activeConversationId: input.conversationId,
          activeWorkspacePath:
            input.target === "worktree"
              ? "/workspace/codegraff-gui-worktree"
              : "/workspace/codegraff-gui",
          conversationViews:
            input.conversationId == null
              ? []
              : [
                  {
                    activeRequestIds: [],
                    conversationId: input.conversationId,
                    followup: null,
                    messages: [],
                    requestAgentIds: {},
                    todos: [],
                    workspacePath:
                      input.target === "worktree"
                        ? "/workspace/codegraff-gui-worktree"
                        : "/workspace/codegraff-gui",
                  },
                ],
          workspaces: [
            {
              configurationError: null,
              configured: true,
              conversations:
                input.conversationId == null
                  ? []
                  : [
                      {
                        conversationId: input.conversationId,
                        hasPendingFollowup: false,
                        isDraft: false,
                        isRunning: false,
                        title: "Selected chat",
                        updatedAt: "2026-04-21T00:00:00.000Z",
                      },
                    ],
              kind: "project",
              selectedConversationId: input.conversationId,
              workspaceName:
                input.target === "worktree" ? "Agent UI Worktree" : "Agent UI",
              workspacePath:
                input.target === "worktree"
                  ? "/workspace/codegraff-gui-worktree"
                  : "/workspace/codegraff-gui",
            },
          ],
        },
      );
    openWorkspaceImpl = async (workspacePath: string) =>
      createSnapshot(workspacePath, "chat-1");
    renameWorkspaceImpl = async (
      workspacePath: string,
      displayName: string | null,
    ) =>
      createSnapshot(workspacePath, "chat-1", {
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
                title: "Selected chat",
                updatedAt: "2026-04-21T00:00:00.000Z",
              },
            ],
            kind: "project",
            selectedConversationId: "chat-1",
            workspaceName: displayName ?? "codegraff-gui",
            workspacePath,
          },
        ],
      });
    renameSavedWorkspaceImpl = async (workspaceId: string, name: string) =>
      createSnapshot("/workspace/codegraff-gui", "chat-1", {
        savedWorkspaces: [{ id: workspaceId, name, updatedAt: 2n }],
      });
    resetSessionStore();
  });

  test("selecting a sidebar chat does not add it to the active saved workspace", async () => {
    sessionStore.getState().setBoardSelection({
      activeChat: {
        conversationId: "chat-1",
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

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.selectConversation("/workspace/other", "chat-9");

    expect(selectConversationCallCount).toBe(1);
    expect(ensureConversationViewCallCount).toBe(0);
    expect(getPromptSettingsCallCount).toBeGreaterThan(0);
    expect(getRuntimeStatusCallCount).toBeGreaterThan(0);
    expect(sessionStore.getState().selection).toEqual({
      chat: {
        conversationId: "chat-9",
        workspacePath: "/workspace/other",
      },
      kind: "single-chat",
    });
  });

  test("stopPrompt targets the active binding", async () => {
    sessionStore.getState().setBoardSelection({
      chat: {
        conversationId: "chat-7",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "single-chat",
    });

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.stopPrompt();

    expect(stopPromptCallCount).toBe(1);
    expect(lastStopPromptInput).toEqual({
      conversationId: "chat-7",
      workspacePath: "/workspace/codegraff-gui",
    });
  });

  test("opening a project keeps the current selection until the snapshot resolves", async () => {
    sessionStore.getState().setBoardSelection({
      activeChat: {
        conversationId: "chat-1",
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

    const workspaceRequest = deferred<SessionSnapshot>();
    openWorkspaceImpl = async () => await workspaceRequest.promise;

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;
    const openProjectPromise = actions.openProject("/workspace/other");

    expect(openWorkspaceCallCount).toBe(1);
    expect(sessionStore.getState().selection).toEqual({
      activeChat: {
        conversationId: "chat-1",
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

    workspaceRequest.resolve(createSnapshot("/workspace/other", "chat-7"));
    await openProjectPromise;

    expect(sessionStore.getState().selection).toEqual({
      chat: {
        conversationId: "chat-7",
        workspacePath: "/workspace/other",
      },
      kind: "single-chat",
    });
  });

  test("starting a sidebar chat without a project creates a managed chat workspace", async () => {
    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.startNewChat();

    expect(createManagedChatCallCount).toBe(1);
    expect(openWorkspaceCallCount).toBe(0);
    expect(selectConversationCallCount).toBe(0);
    expect(sessionStore.getState().selection).toEqual({
      kind: "workspace-draft",
      workspacePath: "/workspace/managed-chat",
    });
  });

  test("starting a sidebar chat reuses an existing empty managed chat draft", async () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot("/workspace/codegraff-gui", "chat-1", {
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [],
            kind: "managed_chat",
            selectedConversationId: null,
            workspaceName: "New chat",
            workspacePath: "/workspace/managed-chat",
          },
          {
            configurationError: null,
            configured: true,
            conversations: [
              {
                conversationId: "chat-1",
                hasPendingFollowup: false,
                isDraft: false,
                isRunning: false,
                title: "Selected chat",
                updatedAt: "2026-04-21T00:00:00.000Z",
              },
            ],
            kind: "project",
            selectedConversationId: "chat-1",
            workspaceName: "Agent UI",
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );
    openWorkspaceImpl = async () =>
      createSnapshot("/workspace/managed-chat", "unused", {
        activeConversationId: null,
        activeWorkspacePath: "/workspace/managed-chat",
        conversationViews: [],
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [],
            kind: "managed_chat",
            selectedConversationId: null,
            workspaceName: "New chat",
            workspacePath: "/workspace/managed-chat",
          },
        ],
      });

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.startNewChat();

    expect(createManagedChatCallCount).toBe(0);
    expect(openWorkspaceCallCount).toBe(1);
    expect(sessionStore.getState().selection).toEqual({
      kind: "workspace-draft",
      workspacePath: "/workspace/managed-chat",
    });
  });

  test("handoffing a chat updates the active selection to the target workspace", async () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot("/workspace/codegraff-gui", "chat-1"),
    );

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.handoffChat({
      branchName: "feature/worktree",
      conversationId: "chat-1",
      sourceWorkspacePath: "/workspace/codegraff-gui",
      target: "worktree",
    });

    expect(handoffChatCallCount).toBe(1);
    expect(sessionStore.getState().selection).toEqual({
      chat: {
        conversationId: "chat-1",
        workspacePath: "/workspace/codegraff-gui-worktree",
      },
      kind: "single-chat",
    });
  });

  test("handoffing a draft chat moves the prompt draft to the target workspace", async () => {
    const sourceDraftKey = getPromptDraftKey("/workspace/codegraff-gui", null);
    if (sourceDraftKey == null) {
      throw new Error("Expected a prompt draft key");
    }

    sessionStore.getState().setPromptDraftValue(sourceDraftKey, "Investigate the bug");

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.handoffChat({
      branchName: "feature/draft-handoff",
      conversationId: null,
      sourceWorkspacePath: "/workspace/codegraff-gui",
      target: "worktree",
    });

    const targetDraftKey = getPromptDraftKey("/workspace/codegraff-gui-worktree", null);
    expect(targetDraftKey).not.toBeNull();
    expect(sessionStore.getState().promptDraftsByKey[sourceDraftKey]).toBeUndefined();
    expect(
      sessionStore.getState().promptDraftsByKey[targetDraftKey as string]?.value,
    ).toBe("Investigate the bug");
  });

  test("submitting a first planning prompt exposes request-agent metadata", async () => {
    const sourceDraftKey = getPromptDraftKey("/workspace/codegraff-gui", null);
    if (sourceDraftKey == null) {
      throw new Error("Expected a prompt draft key");
    }

    sessionStore.getState().applySessionSnapshot(
      createSnapshot("/workspace/codegraff-gui", "unused", {
        activeConversationId: null,
        conversationViews: [],
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [],
            kind: "project",
            selectedConversationId: null,
            workspaceName: "Agent UI",
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );
    sessionStore.getState().setBoardSelection({
      kind: "workspace-draft",
      workspacePath: "/workspace/codegraff-gui",
    });
    sessionStore.getState().setPromptDraftValue(sourceDraftKey, "Make a plan");
    sessionStore.getState().setPromptDraftPlanningMode(sourceDraftKey, true);
    sendPromptImpl = async (input) =>
      createSnapshot(input.workspacePath, "chat-2", {
        activeConversationId: "chat-2",
        conversationViews: [
          {
            activeRequestIds: ["req-plan-1"],
            conversationId: "chat-2",
            followup: null,
            messages: [
              {
                id: "user-1",
                kind: "user",
                requestId: "req-plan-1",
                text: input.prompt,
              },
            ],
            requestAgentIds: { "req-plan-1": "muse" },
            todos: [],
            workspacePath: input.workspacePath,
          },
        ],
        visibleActiveRequestIds: ["req-plan-1"],
        visibleMessages: [
          {
            id: "user-1",
            kind: "user",
            requestId: "req-plan-1",
            text: input.prompt,
          },
        ],
        visibleRequestAgentIds: { "req-plan-1": "muse" },
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [
              {
                conversationId: "chat-2",
                hasPendingFollowup: false,
                isDraft: false,
                isRunning: true,
                title: "Plan chat",
                updatedAt: "2026-04-21T00:00:00.000Z",
              },
            ],
            kind: "project",
            selectedConversationId: "chat-2",
            workspaceName: "Agent UI",
            workspacePath: input.workspacePath,
          },
        ],
      });

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.submitPrompt();

    expect(sendPromptCallCount).toBe(1);
    expect(lastSendPromptInput?.agentId).toBe("muse");
    expect(
      sessionStore.getState().conversationViewsByKey[
        "/workspace/codegraff-gui::chat-2"
      ]?.requestAgentIds,
    ).toEqual({
      "req-plan-1": "muse",
    });
  });

  test("submitting a first planning prompt exposes completed request-agent metadata", async () => {
    const sourceDraftKey = getPromptDraftKey("/workspace/codegraff-gui", null);
    if (sourceDraftKey == null) {
      throw new Error("Expected a prompt draft key");
    }

    sessionStore.getState().applySessionSnapshot(
      createSnapshot("/workspace/codegraff-gui", "unused", {
        activeConversationId: null,
        conversationViews: [],
        workspaces: [
          {
            configurationError: null,
            configured: true,
            conversations: [],
            kind: "project",
            selectedConversationId: null,
            workspaceName: "Agent UI",
            workspacePath: "/workspace/codegraff-gui",
          },
        ],
      }),
    );
    sessionStore.getState().setBoardSelection({
      kind: "workspace-draft",
      workspacePath: "/workspace/codegraff-gui",
    });
    sessionStore.getState().setPromptDraftValue(sourceDraftKey, "Make a plan");
    sessionStore.getState().setPromptDraftPlanningMode(sourceDraftKey, true);
    sendPromptImpl = async (input) =>
      createSnapshot(input.workspacePath, "chat-2", {
        activeConversationId: "chat-2",
        conversationViews: [
          {
            activeRequestIds: [],
            conversationId: "chat-2",
            followup: null,
            messages: [
              {
                id: "user-1",
                kind: "user",
                requestId: "req-plan-complete",
                text: input.prompt,
              },
              {
                id: "assistant-1",
                kind: "assistant",
                requestId: "req-plan-complete",
                text: "Here is the plan.",
              },
            ],
            requestAgentIds: { "req-plan-complete": "muse" },
            todos: [],
            workspacePath: input.workspacePath,
          },
        ],
        visibleActiveRequestIds: [],
        visibleMessages: [
          {
            id: "user-1",
            kind: "user",
            requestId: "req-plan-complete",
            text: input.prompt,
          },
          {
            id: "assistant-1",
            kind: "assistant",
            requestId: "req-plan-complete",
            text: "Here is the plan.",
          },
        ],
        visibleRequestAgentIds: { "req-plan-complete": "muse" },
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
                title: "Plan chat",
                updatedAt: "2026-04-21T00:00:00.000Z",
              },
            ],
            kind: "project",
            selectedConversationId: "chat-2",
            workspaceName: "Agent UI",
            workspacePath: input.workspacePath,
          },
        ],
      });

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.submitPrompt();

    expect(
      sessionStore.getState().conversationViewsByKey[
        "/workspace/codegraff-gui::chat-2"
      ]?.requestAgentIds,
    ).toEqual({
      "req-plan-complete": "muse",
    });
  });

  test("renaming a project updates the workspace label in session state", async () => {
    sessionStore.getState().applySessionSnapshot(
      createSnapshot("/workspace/codegraff-gui", "chat-1"),
    );

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.renameWorkspace("/workspace/codegraff-gui", "Renamed UI");

    expect(renameWorkspaceCallCount).toBe(1);
    expect(sessionStore.getState().workspacesByPath["/workspace/codegraff-gui"]?.workspaceName).toBe(
      "Renamed UI",
    );
    expect(sessionStore.getState().selection).toEqual({
      chat: {
        conversationId: "chat-1",
        workspacePath: "/workspace/codegraff-gui",
      },
      kind: "single-chat",
    });
  });

  test("renaming a saved workspace updates the saved workspace selection", async () => {
    sessionStore.getState().setBoardSelection({
      activeChat: {
        conversationId: "chat-1",
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
      createSnapshot("/workspace/codegraff-gui", "chat-1"),
    );

    let capturedActions:
      | SessionActionsContextValue
      | null = null;

    function CaptureActions() {
      capturedActions = useContext(SessionActionsContext);
      return null;
    }

    renderToStaticMarkup(
      <SessionProvider>
        <CaptureActions />
      </SessionProvider>,
    );

    if (capturedActions == null) {
      throw new Error("Expected session actions to be available");
    }

    const actions =
      capturedActions as SessionActionsContextValue;

    await actions.renameSavedWorkspace("saved-1", "Renamed workspace");

    expect(renameSavedWorkspaceCallCount).toBe(1);
    expect(sessionStore.getState().savedWorkspaces).toEqual([
      { id: "saved-1", name: "Renamed workspace", updatedAt: 2n },
    ]);
    expect(sessionStore.getState().selection).toEqual({
      activeChat: {
        conversationId: "chat-1",
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
});
