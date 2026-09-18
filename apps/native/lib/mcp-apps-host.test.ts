import { expect, test } from "bun:test";
import { hostReply, MCP_APPS_PROTOCOL, parseToolCall } from "./mcp-apps-host";

test("ui/initialize answers with the extension protocol version", () => {
  expect(hostReply({ jsonrpc: "2.0", id: 1, method: "ui/initialize" })).toEqual({
    jsonrpc: "2.0", id: 1, result: { protocolVersion: MCP_APPS_PROTOCOL },
  });
});

test("tools/call is parsed for ACP forwarding, not answered inline", () => {
  expect(hostReply({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "mcp__docs__search" } })).toBeNull();
  expect(parseToolCall({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "mcp__docs__search", arguments: { q: "x" } } }))
    .toEqual({ id: 2, name: "mcp__docs__search", arguments: { q: "x" } });
  expect(parseToolCall({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "write_file" } }))
    .toEqual({ id: 3, name: "write_file", arguments: undefined });
});

test("native engine tool names are not ACP MCP calls", async () => {
  const { callMcpAppTool } = await import("./acp-client");
  await expect(callMcpAppTool("write_file", { path: "/tmp/x" })).rejects.toThrow("mcp__");
});

test("non-RPC traffic is ignored", () => {
  expect(hostReply("ready")).toBeNull();
  expect(hostReply({ method: "ui/initialize" })).toBeNull();
});
