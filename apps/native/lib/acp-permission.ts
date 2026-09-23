export type PermissionRequest = {
  requestId: string;
  sessionId: string;
  toolCall: { toolCallId: string; title?: string };
  options: { optionId: string; name: string; kind: string }[];
};
export function permissionRequest(message: unknown): PermissionRequest | null {
  const m = message as { id?: unknown; method?: unknown; params?: Partial<PermissionRequest> };
  const p = m?.params;
  if (m?.method !== "session/request_permission" || typeof m.id !== "string" || typeof p?.sessionId !== "string" || typeof p.toolCall?.toolCallId !== "string" || !Array.isArray(p.options)) return null;
  const options = p.options.filter(o => typeof o?.optionId === "string" && typeof o.name === "string" && ["allow_once", "allow_always", "reject_once", "reject_always"].includes(o.kind));
  if (!options.length || options.length !== p.options.length) return null;
  return { requestId: m.id, sessionId: p.sessionId, toolCall: p.toolCall, options };
}
export async function answerPermission(chat: string, request: PermissionRequest, optionId: string | null): Promise<void> {
  const response = await fetch("/api/acp", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ chat, method: "session/permission", params: { requestId: request.requestId, sessionId: request.sessionId, optionId } }) });
  if (!response.ok) throw new Error((await response.json()).error ?? "Permission response was not delivered");
}
