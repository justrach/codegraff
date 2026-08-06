import { describe, expect, test } from "bun:test";

import type {
  ConversationViewSnapshot,
  SessionMessage,
} from "@/services/desktop/types/contracts";

import { buildAgentOverview } from "./agentOverview";

function view(messages: SessionMessage[]): ConversationViewSnapshot {
  return {
    workspacePath: "/code/project",
    conversationId: "conversation-1",
    messages,
    activeRequestIds: [],
    requestAgentIds: {},
    todos: [],
    followup: null,
  };
}

function taskStart(
  id: string,
  callId: string,
): Extract<SessionMessage, { kind: "tool_start" }> {
  return {
    kind: "tool_start",
    id,
    requestId: "request-1",
    name: "subagent",
    callId,
    detail: {
      kind: "task",
      agentId: `agent-${id}`,
      label: "Review implementation",
    },
  };
}

function taskEnd(
  id: string,
  callId: string,
  isError = false,
): Extract<SessionMessage, { kind: "tool_end" }> {
  return {
    kind: "tool_end",
    id,
    requestId: "request-1",
    name: "subagent",
    callId,
    summary: isError ? "Review failed" : "Review complete",
    isError,
    detail: null,
  };
}

describe("buildAgentOverview", () => {
  test("shows the current orchestrator and running subagents as active", () => {
    const current = view([taskStart("start-1", "call-1")]);
    current.activeRequestIds = ["request-1"];
    current.requestAgentIds = { "request-1": "forge" };

    const overview = buildAgentOverview({
      views: { current },
      summaries: {},
      currentConversationKey: "current",
    });

    expect(overview.active).toHaveLength(2);
    expect(overview.totalActive).toBe(2);
    expect(overview.active.map((item) => item.label)).toEqual([
      "forge",
      "Review implementation",
    ]);
    expect(overview.recent).toHaveLength(0);
  });

  test("moves completed subagents into recent activity", () => {
    const current = view([
      taskStart("start-1", "call-1"),
      taskEnd("end-1", "call-1"),
    ]);

    const overview = buildAgentOverview({
      views: { current },
      summaries: {},
      currentConversationKey: "current",
    });

    expect(overview.active).toHaveLength(1);
    expect(overview.active[0].status).toBe("idle");
    expect(overview.recent).toHaveLength(1);
    expect(overview.recent[0]).toMatchObject({
      label: "Review implementation",
      detail: "Review complete",
      status: "completed",
    });
  });

  test("prioritizes conversations waiting for human input", () => {
    const waiting = view([]);
    waiting.followup = {
      followupId: "followup-1",
      workspacePath: waiting.workspacePath,
      conversationId: waiting.conversationId,
      requestId: "request-1",
      question: "Choose a direction",
      kind: "single",
      options: [],
    };

    const overview = buildAgentOverview({
      views: { waiting },
      summaries: {},
      currentConversationKey: null,
    });

    expect(overview.needsInput).toBe(1);
    expect(overview.active[0].status).toBe("needs-input");
  });

  test("marks failed subagent calls truthfully", () => {
    const failed = view([
      taskStart("start-1", "call-1"),
      taskEnd("end-1", "call-1", true),
    ]);

    const overview = buildAgentOverview({
      views: { failed },
      summaries: {},
      currentConversationKey: null,
    });

    expect(overview.recent[0]).toMatchObject({
      status: "failed",
      detail: "Review failed",
    });
  });
});
