import { expect, test } from "bun:test";
import { hostReply, MCP_APPS_PROTOCOL } from "./mcp-apps-host";

test("ui/initialize answers with the extension protocol version", () => {
  expect(hostReply({ jsonrpc: "2.0", id: 1, method: "ui/initialize" })).toEqual({
    jsonrpc: "2.0", id: 1, result: { protocolVersion: MCP_APPS_PROTOCOL },
  });
});

test("app-initiated tools/call is refused until the host forwards ACP", () => {
  const reply = hostReply({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "search" } });
  expect(reply).toMatchObject({ jsonrpc: "2.0", id: 2, error: { code: -32000 } });
});

test("non-RPC traffic is ignored", () => {
  expect(hostReply("ready")).toBeNull();
  expect(hostReply({ method: "ui/initialize" })).toBeNull();
});
