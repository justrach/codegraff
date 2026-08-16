import type {
  ConversationSessionSummary,
  ConversationViewSnapshot,
  FollowupRequest,
  SessionMessage,
  SessionRecapStatus,
} from "@/services/desktop/types/contracts";

export type AgentOverviewStatus =
  | "running"
  | "needs-input"
  | "completed"
  | "failed"
  | "idle";

export interface AgentOverviewItem {
  id: string;
  agentId: string;
  conversationId: string;
  conversationTitle: string;
  workspacePath: string;
  kind: "orchestrator" | "subagent";
  label: string;
  detail: string;
  status: AgentOverviewStatus;
  /** Set on orchestrators waiting on a human; the control pane answers it inline. */
  followup: FollowupRequest | null;
  isCurrentConversation: boolean;
  sequence: number;
}

export interface AgentOverviewSnapshot {
  active: AgentOverviewItem[];
  recent: AgentOverviewItem[];
  totalActive: number;
  needsInput: number;
}

interface BuildAgentOverviewInput {
  views: Record<string, ConversationViewSnapshot>;
  summaries: Record<string, ConversationSessionSummary>;
  currentConversationKey: string | null;
}

type ToolStartMessage = Extract<SessionMessage, { kind: "tool_start" }>;
type ToolEndMessage = Extract<SessionMessage, { kind: "tool_end" }>;

function findToolEnd(
  messages: SessionMessage[],
  start: ToolStartMessage,
  startIndex: number,
): ToolEndMessage | null {
  for (let index = startIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (
      message.kind === "tool_end" &&
      message.requestId === start.requestId &&
      message.name === start.name &&
      message.callId === start.callId
    ) {
      return message;
    }
  }
  return null;
}

function latestUserPrompt(messages: SessionMessage[]): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.kind === "user" && message.text.trim().length > 0) {
      return message.text.trim();
    }
  }
  return null;
}

function latestRequestAgent(view: ConversationViewSnapshot): string | null {
  for (let index = view.activeRequestIds.length - 1; index >= 0; index -= 1) {
    const agentId = view.requestAgentIds[view.activeRequestIds[index]];
    if (agentId != null && agentId.length > 0) {
      return agentId;
    }
  }
  return null;
}

function titleForConversation(
  key: string,
  view: ConversationViewSnapshot,
  summaries: Record<string, ConversationSessionSummary>,
): string {
  return summaries[key]?.title ?? latestUserPrompt(view.messages) ?? "Untitled task";
}

function recapStatusToOverview(
  status: SessionRecapStatus,
): AgentOverviewStatus {
  switch (status) {
    case "needs_input":
      return "needs-input";
    case "failed":
      return "failed";
    default:
      return "completed";
  }
}

function buildOrchestrator(
  key: string,
  view: ConversationViewSnapshot,
  summaries: Record<string, ConversationSessionSummary>,
  isCurrentConversation: boolean,
): AgentOverviewItem {
  const activeAgent = latestRequestAgent(view);
  const lastMessage = view.messages.at(-1);
  const recap = view.recap ?? null;
  let status: AgentOverviewStatus = "idle";

  // Live signals win over the recap: it describes the last SETTLED turn
  // (#419), so a running request or a pending followup is always fresher.
  if (view.followup != null) {
    status = "needs-input";
  } else if (view.activeRequestIds.length > 0) {
    status = "running";
  } else if (lastMessage?.kind === "error") {
    status = "failed";
  } else if (recap != null) {
    status = recapStatusToOverview(recap.status);
  }

  return {
    id: `${key}:orchestrator`,
    agentId: activeAgent ?? "root",
    conversationId: view.conversationId,
    conversationTitle: titleForConversation(key, view, summaries),
    workspacePath: view.workspacePath,
    kind: "orchestrator",
    label: activeAgent ?? "Main agent",
    detail:
      recap?.text ??
      view.goal ??
      latestUserPrompt(view.messages) ??
      "Ready for direction",
    status,
    followup: view.followup ?? null,
    isCurrentConversation,
    sequence: view.messages.length,
  };
}

function buildSubagents(
  key: string,
  view: ConversationViewSnapshot,
  summaries: Record<string, ConversationSessionSummary>,
  isCurrentConversation: boolean,
): AgentOverviewItem[] {
  const items: AgentOverviewItem[] = [];

  view.messages.forEach((message, index) => {
    if (message.kind !== "tool_start" || message.detail.kind !== "task") {
      return;
    }

    const end = findToolEnd(view.messages, message, index);
    const status: AgentOverviewStatus =
      end == null ? "running" : end.isError ? "failed" : "completed";

    items.push({
      id: `${key}:subagent:${message.callId ?? message.id}`,
      agentId: message.detail.agentId,
      conversationId: view.conversationId,
      conversationTitle: titleForConversation(key, view, summaries),
      workspacePath: view.workspacePath,
      kind: "subagent",
      label: message.detail.label || message.detail.agentId,
      detail:
        end?.summary ??
        (status === "running" ? "Working in the background" : "Task finished"),
      status,
      followup: null,
      isCurrentConversation,
      sequence: index,
    });
  });

  return items;
}

function priority(item: AgentOverviewItem): number {
  if (item.status === "needs-input") return 0;
  if (item.status === "running") return 1;
  if (item.status === "failed") return 2;
  if (item.status === "idle") return 3;
  return 4;
}

export function buildAgentOverview({
  views,
  summaries,
  currentConversationKey,
}: BuildAgentOverviewInput): AgentOverviewSnapshot {
  const items = Object.entries(views).flatMap(([key, view]) => {
    const isCurrentConversation = key === currentConversationKey;
    return [
      buildOrchestrator(key, view, summaries, isCurrentConversation),
      ...buildSubagents(key, view, summaries, isCurrentConversation),
    ];
  });

  const active = items
    .filter(
      (item) =>
        item.status === "running" ||
        item.status === "needs-input" ||
        (item.kind === "orchestrator" && item.isCurrentConversation),
    )
    .sort(
      (left, right) =>
        priority(left) - priority(right) ||
        Number(right.isCurrentConversation) -
          Number(left.isCurrentConversation) ||
        right.sequence - left.sequence,
    );

  const activeIds = new Set(active.map((item) => item.id));
  // Recent activity: finished subagents, plus settled orchestrators whose
  // recap (#419) gave them a real outcome — an "idle" one has nothing to say.
  const recent = items
    .filter(
      (item) =>
        !activeIds.has(item.id) &&
        (item.kind === "subagent" || item.status !== "idle"),
    )
    .sort((left, right) => right.sequence - left.sequence)
    .slice(0, 6);

  return {
    active,
    recent,
    totalActive: active.filter(
      (item) => item.status === "running" || item.status === "needs-input",
    ).length,
    needsInput: active.filter((item) => item.status === "needs-input").length,
  };
}

/**
 * One spoken-style summary of the overview, used as the control-pane trigger's
 * aria-label/title so the button announces the same thing the pane shows.
 */
export function formatAgentActivityLabel(
  overview: Pick<AgentOverviewSnapshot, "totalActive" | "needsInput">,
): string {
  if (overview.totalActive === 0) {
    return "Agent control — no active agents";
  }

  const activePart = `${overview.totalActive} active`;
  if (overview.needsInput === 0) {
    return `Agent control — ${activePart}`;
  }

  return `Agent control — ${activePart}, ${overview.needsInput} need${overview.needsInput === 1 ? "s" : ""} input`;
}
