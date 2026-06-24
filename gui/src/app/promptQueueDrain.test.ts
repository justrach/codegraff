import { beforeEach, describe, expect, test } from "bun:test";

import {
  finishPromptQueueDrain,
  tryBeginPromptQueueDrain,
} from "./promptQueueDrain";
import { resetSessionStore, sessionStore } from "./sessionStore";
import type { SessionSnapshot } from "@/services/desktop/types/contracts";

function createSnapshot(isRunning = false): SessionSnapshot {
  return {
    activeConversationId: "chat-1",
    activeWorkspacePath: "/workspace/app",
    conversationViews: [
      {
        activeRequestIds: isRunning ? ["req-1"] : [],
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
    visibleActiveRequestIds: isRunning ? ["req-1"] : [],
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
            isRunning,
            title: "Chat",
            updatedAt: "2026-06-24T00:00:00.000Z",
          },
        ],
        kind: "project",
        selectedConversationId: "chat-1",
        workspaceName: "App",
        workspacePath: "/workspace/app",
      },
    ],
  };
}

describe("prompt queue drain", () => {
  beforeEach(() => {
    resetSessionStore();
    sessionStore.getState().applySessionSnapshot(createSnapshot());
    finishPromptQueueDrain("/workspace/app::chat-1");
  });

  test("serializes competing drains for the same prompt key", () => {
    const key = "/workspace/app::chat-1";
    const binding = { conversationId: "chat-1", workspacePath: "/workspace/app" };
    sessionStore.getState().enqueuePrompt(key, {
      attachments: [],
      isPlanningMode: false,
      isUltraMode: false,
      value: "first",
    });
    sessionStore.getState().enqueuePrompt(key, {
      attachments: [],
      isPlanningMode: true,
      isUltraMode: false,
      value: "second",
    });

    let reentrantDrain: ReturnType<typeof tryBeginPromptQueueDrain> = null;
    const unsubscribe = sessionStore.subscribe(() => {
      reentrantDrain ??= tryBeginPromptQueueDrain(key, binding);
    });
    const firstDrain = tryBeginPromptQueueDrain(key, binding);
    unsubscribe();

    expect(firstDrain?.value).toBe("first");
    expect(reentrantDrain).toBeNull();
    expect(tryBeginPromptQueueDrain(key, binding)).toBeNull();
    expect(sessionStore.getState().queuedPromptsByKey[key]).toEqual([
      {
        attachments: [],
        isPlanningMode: true,
        isUltraMode: false,
        value: "second",
      },
    ]);
  });

  test("drains after request-finished clears stale running summaries", () => {
    const key = "/workspace/app::chat-1";
    const binding = { conversationId: "chat-1", workspacePath: "/workspace/app" };
    sessionStore.getState().applySessionSnapshot(createSnapshot(true));
    sessionStore.getState().enqueuePrompt(key, {
      attachments: [],
      isPlanningMode: false,
      isUltraMode: false,
      value: "after finish",
    });

    expect(tryBeginPromptQueueDrain(key, binding)).toBeNull();

    sessionStore.getState().markRequestFinished({
      conversationId: "chat-1",
      requestId: "req-1",
      workspacePath: "/workspace/app",
    });

    expect(
      sessionStore.getState().conversationSummariesByKey[key]?.isRunning,
    ).toBe(false);
    expect(tryBeginPromptQueueDrain(key, binding)?.value).toBe("after finish");
  });
});
