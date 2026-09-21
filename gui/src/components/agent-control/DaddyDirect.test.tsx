import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import type { AgentOverviewItem } from "@/app/projections/agents";

import { DaddyDirectForm, DaddySupervisorBanner } from "./DaddyDirect";

function item(
  overrides: Partial<AgentOverviewItem> = {},
): AgentOverviewItem {
  return {
    id: "orch",
    agentId: "forge",
    conversationId: "conversation-1",
    conversationTitle: "Fix login",
    workspacePath: "/code/project",
    kind: "orchestrator",
    label: "Main agent",
    detail: "Ready",
    status: "idle",
    followup: null,
    isCurrentConversation: false,
    sequence: 0,
    ...overrides,
  };
}

describe("DaddySupervisorBanner", () => {
  test("names the current chat as the supervisor", () => {
    const markup = renderToStaticMarkup(
      <DaddySupervisorBanner title="Fix login" />,
    );
    expect(markup).toContain("Supervisor");
    expect(markup).toContain("Directing from Fix login");
  });

  test("explains how to start when no chat is focused", () => {
    const markup = renderToStaticMarkup(
      <DaddySupervisorBanner title={null} />,
    );
    expect(markup).toContain("Open a chat to supervise from it");
  });
});

describe("DaddyDirectForm", () => {
  test("offers Direct on a living orchestrator", () => {
    const markup = renderToStaticMarkup(
      <DaddyDirectForm item={item()} onDirect={() => {}} />,
    );
    expect(markup).toContain('aria-label="Direct Main agent"');
    expect(markup).toContain("Direct");
  });

  test("hides Direct on a failed orchestrator or finished child", () => {
    const failed = renderToStaticMarkup(
      <DaddyDirectForm
        item={item({ status: "failed" })}
        onDirect={() => {}}
      />,
    );
    expect(failed).toBe("");
    const done = renderToStaticMarkup(
      <DaddyDirectForm
        item={item({ kind: "subagent", status: "completed", label: "Scout" })}
        onDirect={() => {}}
      />,
    );
    expect(done).toBe("");
  });
});
