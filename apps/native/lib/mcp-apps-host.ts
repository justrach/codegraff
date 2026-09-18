/** MCP Apps extension dialect (ui/* over postMessage). Snapshot HTML still
 *  renders without this; app-initiated tools stay refused until the host
 *  forwards them through ACP. Spec: 2026-01-26. */

export const MCP_APPS_PROTOCOL = "2026-01-26";

type JsonRpc = { jsonrpc?: string; id?: unknown; method?: string; params?: unknown };

export type HostReply =
  | { jsonrpc: "2.0"; id: unknown; result: unknown }
  | { jsonrpc: "2.0"; id: unknown; error: { code: number; message: string } };

export function hostReply(data: unknown): HostReply | null {
  if (!data || typeof data !== "object") return null;
  const msg = data as JsonRpc;
  if (msg.jsonrpc !== "2.0" || typeof msg.method !== "string" || msg.id === undefined) return null;
  if (msg.method === "ui/initialize") {
    return { jsonrpc: "2.0", id: msg.id, result: { protocolVersion: MCP_APPS_PROTOCOL } };
  }
  if (msg.method === "tools/call" || msg.method.startsWith("ui/")) {
    return { jsonrpc: "2.0", id: msg.id, error: { code: -32000, message: "Host-mediated MCP App tool calls are not enabled yet." } };
  }
  return null;
}
