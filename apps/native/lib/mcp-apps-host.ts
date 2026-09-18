/** MCP Apps extension dialect (ui/* over postMessage). Spec: 2026-01-26. */

export const MCP_APPS_PROTOCOL = "2026-01-26";

type JsonRpc = { jsonrpc?: string; id?: unknown; method?: string; params?: unknown };

export type HostReply =
  | { jsonrpc: "2.0"; id: unknown; result: unknown }
  | { jsonrpc: "2.0"; id: unknown; error: { code: number; message: string } };

export type ToolCall = { id: unknown; name: string; arguments: unknown };

export function parseToolCall(data: unknown): ToolCall | null {
  if (!data || typeof data !== "object") return null;
  const msg = data as JsonRpc;
  if (msg.jsonrpc !== "2.0" || msg.method !== "tools/call" || msg.id === undefined) return null;
  const params = msg.params && typeof msg.params === "object" ? msg.params as { name?: unknown; arguments?: unknown } : {};
  if (typeof params.name !== "string" || !params.name) return null;
  return { id: msg.id, name: params.name, arguments: params.arguments };
}

export function hostReply(data: unknown): HostReply | null {
  if (!data || typeof data !== "object") return null;
  const msg = data as JsonRpc;
  if (msg.jsonrpc !== "2.0" || typeof msg.method !== "string" || msg.id === undefined) return null;
  if (msg.method === "tools/call") return null;
  if (msg.method === "ui/initialize") {
    return { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: MCP_APPS_PROTOCOL } };
  }
  if (msg.method.startsWith("ui/")) {
    return { jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: "Host-mediated MCP App tool calls are not enabled yet." } };
  }
  return null;
}

export function toolCallError(id: unknown, message: string): HostReply {
  return { jsonrpc: "2.0", id, error: { code: -32000, message } };
}

export function toolCallResult(id: unknown, result: unknown): HostReply {
  return { jsonrpc: "2.0", id, result };
}
