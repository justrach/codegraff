import type { AssistantTurn } from "./graff-events";
export function turnActivity(turn: AssistantTurn, now: number) {
  const live = turn.status === "thinking" || turn.status === "streaming";
  const elapsed = Math.max(0, Math.floor((now - (turn.startedAt ?? now)) / 1000));
  const idle = Math.max(0, Math.floor((now - (turn.lastUpdateAt ?? turn.startedAt ?? now)) / 1000));
  const running = turn.tools.filter(tool => tool.status === "running").length;
  const missing = turn.tools.filter(tool => tool.status === "interrupted").length;
  if (turn.status === "error") return { state: "error", label: "Response interrupted", detail: "You can send a follow-up to continue.", live: false };
  if (turn.status === "ask") return { state: "input", label: "Waiting for your answer", detail: "", live: false };
  if (!live) return { state: "done", label: turn.stopReason === "cancelled" ? "Stopped" : "Turn finished", detail: missing ? `${missing} tool ${missing === 1 ? "result" : "results"} not received` : `${elapsed}s`, live: false };
  const label = !turn.connected ? "Starting Graff…" : running ? `Running ${running} ${running === 1 ? "tool" : "tools"}…` : turn.activityKind === "agent_thought_chunk" ? "Thinking…" : turn.activityKind === "agent_message_chunk" && idle < 2 ? "Writing response…" : "Waiting for Graff…";
  return { state: idle >= 15 ? "waiting" : "working", label, detail: idle >= 15 ? `No update for ${idle}s · You can stop this turn` : `${elapsed}s`, live: true };
}
