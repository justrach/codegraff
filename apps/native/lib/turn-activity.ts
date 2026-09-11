import type { AssistantTurn } from "./graff-events";

export function workDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor(total % 3600 / 60)}m`;
}

export function turnActivity(turn: AssistantTurn, now: number, opts?: { snapshot?: boolean }) {
  if (turn.status === "snapshot" || opts?.snapshot) return { state: "snapshot", label: "Saved snapshot", detail: "Live status unknown", live: false };
  const live = turn.status === "thinking" || turn.status === "streaming";
  const end = live ? now : turn.endedAt ?? turn.lastUpdateAt ?? turn.startedAt ?? now;
  const duration = workDuration((end - (turn.startedAt ?? end)) / 1000);
  const idle = Math.max(0, Math.floor((now - (turn.lastUpdateAt ?? turn.startedAt ?? now)) / 1000));
  const running = turn.tools.filter(tool => tool.status === "running").length;
  const missing = turn.tools.filter(tool => tool.status === "interrupted").length;
  if (turn.status === "error") return { state: "error", label: "Response interrupted", detail: `After ${duration}. ${turn.tools.some(tool => tool.status === "ok") ? "Completed tool results are kept. " : ""}Send a follow-up to continue.`, live: false };
  if (turn.status === "ask") return { state: "input", label: "Waiting for your answer", detail: "", live: false };
  if (!live) return { state: "done", label: turn.stopReason === "cancelled" ? "Stopped" : `Worked for ${duration}`, detail: turn.stopReason === "cancelled" ? `After ${duration}` : missing ? `${missing} tool ${missing === 1 ? "result" : "results"} not received` : "", live: false };
  const detail = !turn.connected ? "Starting…" : running ? `Running ${running} ${running === 1 ? "tool" : "tools"}…` : turn.activityKind === "agent_thought_chunk" ? "Thinking…" : turn.activityKind === "agent_message_chunk" && idle < 2 ? "Writing…" : "";
  return { state: idle >= 15 ? "waiting" : "working", label: `Working for ${duration}`, detail: idle >= 15 ? `${detail ? `${detail} · ` : ""}No update for ${workDuration(idle)}` : detail, live: true };
}
