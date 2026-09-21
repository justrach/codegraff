import type { AssistantTurn } from "./graff-events";

export function workDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  if (total < 60) return `${total}s`;
  if (total < 3600) return `${Math.floor(total / 60)}m ${total % 60}s`;
  return `${Math.floor(total / 3600)}h ${Math.floor(total % 3600 / 60)}m`;
}

/** Local estimate until a usage event lands: codepoints / 4. */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.max(1, Math.round([...text].length / 4));
}

export function tokPerSec(tokens: number, elapsedMs: number): string | null {
  if (tokens < 1 || elapsedMs < 400) return null;
  const rate = tokens / (elapsedMs / 1000);
  if (!Number.isFinite(rate) || rate <= 0) return null;
  return rate >= 10 ? `${Math.round(rate)} tok/s` : `${rate.toFixed(1)} tok/s`;
}

function joinDetail(...parts: (string | null | undefined)[]): string {
  return parts.filter(Boolean).join(" · ");
}

export function turnActivity(turn: AssistantTurn, now: number, opts?: { snapshot?: boolean }) {
  if (turn.status === "snapshot" || opts?.snapshot) return { state: "snapshot", label: "Saved snapshot", detail: "Live status unknown", live: false };
  const live = turn.status === "thinking" || turn.status === "streaming";
  const end = live ? now : turn.endedAt ?? turn.lastUpdateAt ?? turn.startedAt ?? now;
  const elapsedMs = Math.max(0, end - (turn.startedAt ?? end));
  const duration = workDuration(elapsedMs / 1000);
  const idle = Math.max(0, Math.floor((now - (turn.lastUpdateAt ?? turn.startedAt ?? now)) / 1000));
  const running = turn.tools.filter(tool => tool.status === "running").length;
  const mcpApps = turn.tools.filter(tool => tool.status === "running" && tool.mcpAppId).length;
  const missing = turn.tools.filter(tool => tool.status === "interrupted").length;
  const rate = running ? null : tokPerSec(estimateTokens(turn.text), elapsedMs);
  if (turn.status === "error") return { state: "error", label: "Response interrupted", detail: `After ${duration}. ${turn.tools.some(tool => tool.status === "ok") ? "Completed tool results are kept. " : ""}Retry or send a follow-up to continue.`, live: false };
  if (turn.status === "ask") return { state: "input", label: "Waiting for your answer", detail: "", live: false };
  if (!live) {
    const wait = missing ? `${missing} tool ${missing === 1 ? "result" : "results"} not received` : rate;
    return { state: "done", label: turn.stopReason === "cancelled" ? "Stopped" : `Worked for ${duration}`, detail: turn.stopReason === "cancelled" ? `After ${duration}` : wait ?? "", live: false };
  }
  const waitingOn = mcpApps ? `Waiting on ${mcpApps === 1 ? "MCP App" : "MCP Apps"}…` : running ? `Running ${running} ${running === 1 ? "tool" : "tools"}…` : turn.retryNotice ? turn.retryNotice : "";
  const writing = !turn.connected ? "Starting…" : waitingOn || (turn.activityKind === "agent_thought_chunk" ? "Thinking…" : turn.activityKind === "agent_message_chunk" && idle < 2 ? "Writing…" : "");
  const detail = idle >= 15 ? joinDetail(writing, `No update for ${workDuration(idle)}`) : joinDetail(writing, waitingOn ? null : rate);
  return { state: idle >= 15 ? "waiting" : "working", label: `Working for ${duration}`, detail, live: true };
}

/** Human framing for a failed turn: who failed, then the provider's own words.
 * The provider id is whatever prefixes the harness's `<provider> api error:`
 * text (or the turn's spawn provider); nothing vendor-specific is hardcoded. */
export function describeTurnError(error: string, provider?: string): { framing: string; message: string } {
  const text = error.trim();
  const api = /^(?:([a-z0-9][\w.-]*)\s+)?api error(?:\s*\([^)]*\))?\s*:\s*([\s\S]*)$/i.exec(text);
  if (api) {
    const who = api[1] ?? provider;
    return { framing: who ? `${who} failed mid-response` : "The model provider failed mid-response", message: api[2].trim() || text };
  }
  if (/\b(exited|disconnected|closed|not running)\b/i.test(text)) return { framing: "The agent stopped before finishing", message: text };
  return { framing: provider ? `${provider} failed mid-response` : "The request failed", message: text };
}
