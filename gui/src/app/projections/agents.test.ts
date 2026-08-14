import { describe, expect, test } from "bun:test";

import type {
  ConversationViewSnapshot,
  SessionMessage,
} from "@/services/desktop/types/contracts";

import { buildAgentOverview, formatAgentActivityLabel } from "./agents";

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
    expect(overview.active[0].followup?.followupId).toBe("followup-1");
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

  // #419: the harness session_recap feeds the settled orchestrator's chip
  // and one-line detail; live signals always outrank it.
  test("uses the harness recap for a settled orchestrator", () => {
    const settled = view([
      { kind: "user", id: "u1", requestId: "request-1", text: "ship it" },
    ]);
    settled.recap = {
      text: "Fixed the login redirect loop",
      status: "completed",
      source: "model",
    };

    const overview = buildAgentOverview({
      views: { settled },
      summaries: {},
      currentConversationKey: null,
    });

    // not the current conversation: the settled session shows in recent
    // activity with its recap text and completed chip
    expect(overview.active).toHaveLength(0);
    expect(overview.recent[0]).toMatchObject({
      status: "completed",
      detail: "Fixed the login redirect loop",
    });

    // the current conversation stays in the active list, recap included
    const current = buildAgentOverview({
      views: { settled },
      summaries: {},
      currentConversationKey: "settled",
    });
    expect(current.active[0]).toMatchObject({
      status: "completed",
      detail: "Fixed the login redirect loop",
    });
  });

  test("maps a needs_input recap to the needs-input chip", () => {
    const waiting = view([
      { kind: "user", id: "u1", requestId: "request-1", text: "ship it" },
    ]);
    waiting.recap = {
      text: "Waiting on the user to pick a layout",
      status: "needs_input",
      source: "heuristic",
    };

    const overview = buildAgentOverview({
      views: { waiting },
      summaries: {},
      currentConversationKey: null,
    });

    expect(overview.needsInput).toBe(1);
    expect(overview.active[0].status).toBe("needs-input");
  });

  test("live signals outrank a stale recap", () => {
    const running = view([
      { kind: "user", id: "u1", requestId: "request-1", text: "ship it" },
    ]);
    running.activeRequestIds = ["request-1"];
    running.recap = {
      text: "Fixed the login redirect loop",
      status: "completed",
      source: "heuristic",
    };

    const overview = buildAgentOverview({
      views: { running },
      summaries: {},
      currentConversationKey: null,
    });

    expect(overview.active[0].status).toBe("running");
    // the recap still describes what the session is about
    expect(overview.active[0].detail).toBe("Fixed the login redirect loop");
  });
});

describe("formatAgentActivityLabel", () => {
  test("announces idle when nothing is active", () => {
    expect(formatAgentActivityLabel({ totalActive: 0, needsInput: 0 })).toBe(
      "Agent control — no active agents",
    );
  });

  test("announces the active count", () => {
    expect(formatAgentActivityLabel({ totalActive: 1, needsInput: 0 })).toBe(
      "Agent control — 1 active",
    );
  });

  test("announces how many agents need input", () => {
    expect(formatAgentActivityLabel({ totalActive: 3, needsInput: 1 })).toBe(
      "Agent control — 3 active, 1 needs input",
    );
    expect(formatAgentActivityLabel({ totalActive: 2, needsInput: 2 })).toBe(
      "Agent control — 2 active, 2 need input",
    );
  });
});
