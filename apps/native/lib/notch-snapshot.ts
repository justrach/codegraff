import { turnActivity } from "./turn-activity";
import type { AssistantTurn } from "./graff-events";

export type NotchState = "working" | "waiting" | "idle" | "error";
export type NotchCell = {
  id: number;
  title: string;
  state: NotchState;
  label: string;
  detail: string;
};
export type NotchChat = {
  id: number;
  title: string | null;
  snapshot?: boolean;
  messages: Array<{ role: string; turn?: AssistantTurn }>;
};

export const NOTCH_CELL_LIMIT = 6;
export const NOTCH_TITLE_LIMIT = 80;

const RANK: Record<NotchState, number> = { waiting: 0, working: 1, error: 2, idle: 3 };

function clip(text: string, limit: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= limit) return trimmed;
  return `${trimmed.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

export function notchCell(chat: NotchChat, busy: boolean, now: number): NotchCell {
  const title = clip(chat.title || `Chat ${chat.id}`, NOTCH_TITLE_LIMIT);
  const last = [...chat.messages].reverse().find((message) => message.role === "assistant" && message.turn);
  if (!last?.turn) {
    return {
      id: chat.id,
      title,
      state: busy ? "working" : "idle",
      label: busy ? "Starting…" : "Idle",
      detail: "",
    };
  }
  const activity = turnActivity(last.turn, now, { snapshot: chat.snapshot });
  let state: NotchState = "idle";
  if (activity.state === "error") state = "error";
  else if (activity.state === "input" || activity.state === "waiting") state = "waiting";
  else if (activity.state === "working" || busy) state = "working";
  return {
    id: chat.id,
    title,
    state,
    label: clip(activity.label, 48),
    detail: clip(activity.detail, 120),
  };
}

/** Open chats for the edge observer, live work first, at most six cells. */
export function notchSnapshot(chats: NotchChat[], busy: ReadonlySet<number>, now: number): NotchCell[] {
  if (chats.length === 0) {
    return [{ id: 0, title: "Codegraff", state: "idle", label: "Idle", detail: "" }];
  }
  return chats
    .map((chat) => notchCell(chat, busy.has(chat.id), now))
    .sort((a, b) => RANK[a.state] - RANK[b.state] || a.id - b.id)
    .slice(0, NOTCH_CELL_LIMIT);
}
