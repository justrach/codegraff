import { turnActivity } from "./turn-activity";
import type { AssistantTurn } from "./graff-events";

export type NotchState = "working" | "waiting" | "idle" | "error";
export type NotchKind = "session" | "agent" | "usage";
export type NotchCell = {
  id: number;
  title: string;
  caption: string;
  state: NotchState;
  label: string;
  detail: string;
  kind: NotchKind;
  percent?: number;
};
export type NotchChat = {
  id: number;
  title: string | null;
  snapshot?: boolean;
  messages: Array<{ role: string; turn?: AssistantTurn; text?: string }>;
};
export type NotchAgent = { session: string; pid: number; title: string; task: string; status: string; workspace?: string };

export const NOTCH_CELL_LIMIT = 6;
export const NOTCH_ACTIVITY_LIMIT = 4;
export const NOTCH_TITLE_LIMIT = 80;

const RANK: Record<NotchState, number> = { waiting: 0, working: 1, error: 2, idle: 3 };

function clip(text: string, limit: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= limit) return trimmed;
  return `${trimmed.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

function shortName(raw: string): string {
  const text = raw.replace(/^mcp__/, "").replace(/__/g, " ").replace(/[_-]+/g, " ").trim();
  const word = text.split(/\s+/)[0] || "work";
  return clip(word.toLowerCase(), 8);
}

function runningTool(turn: AssistantTurn): string | null {
  const row = turn.tools.find((tool) => tool.status === "running");
  if (!row) return null;
  return shortName(row.chip || row.name || "tool");
}

export function notchCaption(state: NotchState, detail: string, tool: string | null): string {
  if (tool) return tool;
  if (state === "waiting") return "ask";
  if (state === "error") return "err";
  if (state === "idle") return "idle";
  if (/thinking/i.test(detail)) return "think";
  if (/writing/i.test(detail)) return "write";
  return "work";
}

export function notchCell(chat: NotchChat, busy: boolean, now: number): NotchCell {
  const title = clip(chat.title || `Chat ${chat.id}`, NOTCH_TITLE_LIMIT);
  const last = [...chat.messages].reverse().find((message) => message.role === "assistant" && message.turn);
  const spoke = chat.messages.some((message) => message.role === "user" || message.role === "assistant");
  if (!last?.turn) {
    const state: NotchState = busy ? "working" : "idle";
    const label = busy ? (spoke ? "Working" : "Starting…") : "Idle";
    return {
      id: chat.id, title, caption: notchCaption(state, label, null), state, label, detail: "", kind: "session",
    };
  }
  const activity = turnActivity(last.turn, now, { snapshot: chat.snapshot });
  let state: NotchState = "idle";
  if (activity.state === "error") state = "error";
  else if (activity.state === "input" || activity.state === "waiting") state = "waiting";
  else if (activity.state === "working" || busy) state = "working";
  const tool = state === "working" ? runningTool(last.turn) : null;
  const detail = [activity.detail, tool ? `ACP ${tool}` : ""].filter(Boolean).join(" · ");
  return {
    id: chat.id,
    title,
    caption: notchCaption(state, activity.detail, tool),
    state,
    label: clip(activity.label, 48),
    detail: clip(detail, 120),
    kind: "session",
  };
}

export function agentCells(agents: NotchAgent[]): NotchCell[] {
  return agents
    .filter((agent) => agent.status === "working")
    .map((agent) => {
      const title = clip(agent.title || agent.session || "Agent", NOTCH_TITLE_LIMIT);
      const task = clip(agent.task || "Working", 120);
      return {
        id: cellId(agent.session || String(agent.pid)),
        title,
        caption: shortName(agent.task || "work"),
        state: "working" as const,
        label: task || "Working",
        detail: clip(agent.workspace || "", 120),
        kind: "agent" as const,
      };
    });
}

export function usageCell(id: string, title: string, percent: number, detail: string): NotchCell {
  const used = Math.max(0, Math.min(100, Math.round(percent)));
  const state: NotchState = used >= 100 ? "error" : used >= 80 ? "waiting" : "working";
  return {
    id: cellId(`usage:${id}`),
    title,
    caption: `${used}%`,
    state,
    label: `${title} ${used}%`,
    detail: clip(detail, 120),
    kind: "usage",
    percent: used,
  };
}

function cellId(key: string): number {
  let hash = 0;
  for (let i = 0; i < key.length; i++) hash = (Math.imul(hash, 31) + key.charCodeAt(i)) | 0;
  if (hash === 0) return -1;
  return hash > 0 ? -hash : hash;
}

/** Live ACP work first. Idle chats do not occupy the notch. */
export function notchSnapshot(
  chats: NotchChat[],
  busy: ReadonlySet<number>,
  now: number,
  agents: NotchAgent[] = [],
  usage: NotchCell[] = [],
): NotchCell[] {
  const live = chats
    .map((chat) => notchCell(chat, busy.has(chat.id), now))
    .filter((cell) => cell.state !== "idle")
    .sort((a, b) => RANK[a.state] - RANK[b.state] || a.id - b.id);
  const activity = [...live, ...agentCells(agents)].slice(0, NOTCH_ACTIVITY_LIMIT);
  const limits = usage.filter((cell) => cell.kind === "usage").slice(0, NOTCH_CELL_LIMIT - activity.length);
  const cells = [...activity, ...limits].slice(0, NOTCH_CELL_LIMIT);
  if (cells.length === 0) {
    return [{ id: 0, title: "Codegraff", caption: "idle", state: "idle", label: "Idle", detail: "", kind: "session" }];
  }
  return cells;
}
