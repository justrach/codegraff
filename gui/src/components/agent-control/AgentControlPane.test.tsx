import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import type {
  AgentOverviewItem,
  AgentOverviewSnapshot,
} from "@/app/projections/agents";
import type { FollowupRequest } from "@/services/desktop/types/contracts";

import { AgentControlPaneContent } from "./AgentControlPane";

function item(
  id: string,
  status: AgentOverviewItem["status"],
  overrides: Partial<AgentOverviewItem> = {},
): AgentOverviewItem {
  return {
    id,
    agentId: `agent-${id}`,
    conversationId: `conversation-${id}`,
    conversationTitle: `Task ${id}`,
    workspacePath: "/code/project",
    kind: "subagent",
    label: `Agent ${id}`,
    detail: `Detail ${id}`,
    status,
    followup: null,
    isCurrentConversation: false,
    sequence: 0,
    ...overrides,
  };
}

function overview(
  active: AgentOverviewItem[],
  recent: AgentOverviewItem[] = [],
): AgentOverviewSnapshot {
  return {
    active,
    recent,
    totalActive: active.filter(
      (entry) =>
        entry.status === "running" || entry.status === "needs-input",
    ).length,
    needsInput: active.filter((entry) => entry.status === "needs-input")
      .length,
  };
}

function renderContent(snapshot: AgentOverviewSnapshot): string {
  return renderToStaticMarkup(
    <AgentControlPaneContent
      overview={snapshot}
      stopPendingId={null}
      onClose={() => {}}
      onSelect={() => {}}
      onRequestStop={() => {}}
      onCancelStop={() => {}}
      onConfirmStop={() => {}}
      onAnswerFollowup={() => {}}
    />,
  );
}

describe("AgentControlPaneContent", () => {
  test("shows the empty state when nothing is active or recent", () => {
    const markup = renderContent(overview([]));
    expect(markup).toContain("Agent control");
    expect(markup).toContain("No active work");
    expect(markup).toContain("Agents appear here when work begins.");
  });

  test("lists active agents with status chips in the given order", () => {
    const snapshot = overview([
      item("first", "needs-input"),
      item("second", "running"),
      item("third", "idle"),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).toContain("Needs input");
    expect(markup).toContain("Working");
    expect(markup).toContain("Ready");
    expect(markup).toContain("2 active · 1 needs input");
    expect(markup.indexOf("Agent first")).toBeLessThan(
      markup.indexOf("Agent second"),
    );
    expect(markup.indexOf("Agent second")).toBeLessThan(
      markup.indexOf("Agent third"),
    );
  });

  test("lists recent agents under their own section", () => {
    const snapshot = overview(
      [item("active", "running")],
      [item("done", "completed")],
    );
    const markup = renderContent(snapshot);
    expect(markup).toContain("Recent");
    expect(markup).toContain("Agent done");
  });

  test("marks the current conversation card", () => {
    const snapshot = overview([
      item("current", "idle", { isCurrentConversation: true }),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).toContain("agent-overview-card is-current");
  });

  test("offers stop only for a running orchestrator, never for subagents", () => {
    const snapshot = overview([
      item("orch", "running", { kind: "orchestrator" }),
      item("sub", "running", { kind: "subagent" }),
      item("done", "completed", { kind: "orchestrator" }),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).toContain('aria-label="Stop Agent orch"');
    expect(markup).not.toContain('aria-label="Stop Agent sub"');
    expect(markup).not.toContain('aria-label="Stop Agent done"');
  });

  test("renders the followup question with single-choice options inline", () => {
    const followup: FollowupRequest = {
      followupId: "followup-1",
      workspacePath: "/code/project",
      conversationId: "conversation-orch",
      requestId: "request-1",
      kind: "single",
      question: "Which direction?",
      options: [
        { id: "opt-a", label: "Option A" },
        { id: "opt-b", label: "Option B" },
      ],
    };
    const snapshot = overview([
      item("orch", "needs-input", { kind: "orchestrator", followup }),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).toContain("Which direction?");
    expect(markup).toContain("Option A");
    expect(markup).toContain("Option B");
    expect(markup).toContain("Dismiss");
  });

  test("renders a text input for free-text followups", () => {
    const followup: FollowupRequest = {
      followupId: "followup-2",
      workspacePath: "/code/project",
      conversationId: "conversation-orch",
      requestId: "request-1",
      kind: "text",
      question: "What should I name it?",
      options: null,
    };
    const snapshot = overview([
      item("orch", "needs-input", { kind: "orchestrator", followup }),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).toContain("What should I name it?");
    expect(markup).toContain('aria-label="Answer"');
  });

  test("subagents never carry followup controls", () => {
    const followup: FollowupRequest = {
      followupId: "followup-3",
      workspacePath: "/code/project",
      conversationId: "conversation-sub",
      requestId: "request-1",
      kind: "single",
      question: "Should not render",
      options: [{ id: "opt-a", label: "Option A" }],
    };
    const snapshot = overview([
      item("sub", "needs-input", { kind: "subagent", followup }),
    ]);
    const markup = renderContent(snapshot);
    expect(markup).not.toContain("Should not render");
  });
});
