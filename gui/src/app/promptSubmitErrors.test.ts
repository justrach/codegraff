import { describe, expect, test } from "bun:test";

import {
  isActivePromptConflictError,
  snapshotConfirmsPromptAccepted,
  snapshotHasActiveRequest,
} from "./promptSubmitErrors";

describe("snapshotHasActiveRequest", () => {
  test("matches active requests for the target binding", () => {
    expect(
      snapshotHasActiveRequest(
        {
          activeConversationId: "chat-1",
          activeWorkspacePath: "/workspace/app",
          conversationViews: [
            {
              activeRequestIds: ["req-1"],
              conversationId: "chat-1",
              followup: null,
              messages: [],
              requestAgentIds: {},
              todos: [],
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: ["req-1"],
          visibleFollowup: null,
          visibleMessages: [],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: "chat-1", workspacePath: "/workspace/app" },
      ),
    ).toBe(true);
  });

  test("falls back to workspace running summaries for non-visible conversations", () => {
    expect(
      snapshotHasActiveRequest(
        {
          activeConversationId: "chat-visible",
          activeWorkspacePath: "/workspace/app",
          conversationViews: [
            {
              activeRequestIds: [],
              conversationId: "chat-visible",
              followup: null,
              messages: [],
              requestAgentIds: {},
              todos: [],
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
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
                  conversationId: "chat-hidden",
                  hasPendingFollowup: false,
                  isDraft: false,
                  isRunning: true,
                  title: "Hidden running chat",
                  updatedAt: "2026-06-24T00:00:00.000Z",
                },
              ],
              kind: "project",
              selectedConversationId: "chat-visible",
              workspaceName: "App",
              workspacePath: "/workspace/app",
            },
          ],
        },
        { conversationId: "chat-hidden", workspacePath: "/workspace/app" },
      ),
    ).toBe(true);
  });
});

describe("snapshotConfirmsPromptAccepted", () => {
  test("detects accepted prompts in refreshed conversation views", () => {
    expect(
      snapshotConfirmsPromptAccepted(
        {
          activeConversationId: "chat-1",
          activeWorkspacePath: "/workspace/app",
          conversationViews: [
            {
              activeRequestIds: ["req-1"],
              conversationId: "chat-1",
              followup: null,
              messages: [
                {
                  id: "user-1",
                  kind: "user",
                  requestId: "req-1",
                  text: "Already sent",
                },
              ],
              requestAgentIds: {},
              todos: [],
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: ["req-1"],
          visibleFollowup: null,
          visibleMessages: [],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: "chat-1", workspacePath: "/workspace/app" },
        "Already sent",
      ),
    ).toBe(true);
  });

  test("does not treat historical duplicate user text as a fresh acceptance", () => {
    expect(
      snapshotConfirmsPromptAccepted(
        {
          activeConversationId: "chat-1",
          activeWorkspacePath: "/workspace/app",
          conversationViews: [
            {
              activeRequestIds: ["req-current"],
              conversationId: "chat-1",
              followup: null,
              messages: [
                {
                  id: "user-old",
                  kind: "user",
                  requestId: "req-old",
                  text: "ok",
                },
                {
                  id: "assistant-current",
                  kind: "assistant",
                  requestId: "req-current",
                  text: "Working",
                },
              ],
              requestAgentIds: {},
              todos: [],
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: ["req-current"],
          visibleFollowup: null,
          visibleMessages: [],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: "chat-1", workspacePath: "/workspace/app" },
        "ok",
      ),
    ).toBe(false);
  });

  test("does not treat idle latest duplicate user text as acceptance", () => {
    expect(
      snapshotConfirmsPromptAccepted(
        {
          activeConversationId: "chat-1",
          activeWorkspacePath: "/workspace/app",
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
                  text: "ok",
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
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: [],
          visibleFollowup: null,
          visibleMessages: [],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: "chat-1", workspacePath: "/workspace/app" },
        "ok",
      ),
    ).toBe(false);
  });

  test("does not treat another workspace conversation as accepted first prompt", () => {
    expect(
      snapshotConfirmsPromptAccepted(
        {
          activeConversationId: null,
          activeWorkspacePath: "/workspace/app",
          conversationViews: [
            {
              activeRequestIds: ["req-old"],
              conversationId: "chat-old",
              followup: null,
              messages: [
                {
                  id: "user-old",
                  kind: "user",
                  requestId: "req-old",
                  text: "Fix tests",
                },
              ],
              requestAgentIds: {},
              todos: [],
              workspacePath: "/workspace/app",
            },
          ],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: [],
          visibleFollowup: null,
          visibleMessages: [],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: null, workspacePath: "/workspace/app" },
        "Fix tests",
      ),
    ).toBe(false);
  });

  test("detects accepted first prompts in the active visible conversation", () => {
    expect(
      snapshotConfirmsPromptAccepted(
        {
          activeConversationId: "chat-new",
          activeWorkspacePath: "/workspace/app",
          conversationViews: [],
          savedWorkspaces: [],
          uiError: null,
          visibleActiveRequestIds: ["req-1"],
          visibleFollowup: null,
          visibleMessages: [
            {
              id: "user-1",
              kind: "user",
              requestId: "req-1",
              text: "First prompt",
            },
          ],
          visibleRequestAgentIds: {},
          visibleTodos: [],
          workspaces: [],
        },
        { conversationId: null, workspacePath: "/workspace/app" },
        "First prompt",
      ),
    ).toBe(true);
  });
});

describe("isActivePromptConflictError", () => {
  test("detects backend active prompt conflicts", () => {
    expect(
      isActivePromptConflictError(
        new Error("conversation already has an active prompt"),
      ),
    ).toBe(true);
  });

  test("ignores unrelated send errors", () => {
    expect(isActivePromptConflictError(new Error("network down"))).toBe(false);
  });
});
