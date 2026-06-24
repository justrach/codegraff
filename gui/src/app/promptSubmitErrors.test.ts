import { describe, expect, test } from "bun:test";

import {
  isActivePromptConflictError,
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
